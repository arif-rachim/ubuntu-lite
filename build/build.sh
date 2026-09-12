#!/bin/bash
# ubuntu-lite image builder.
#   sudo build/build.sh                 full build -> out/<name>-<build-id>.iso
#   sudo build/build.sh --from iso      resume from a stage (rootfs packages customize pool squashfs iso)
#   sudo build/build.sh --only squashfs run a single stage
# Requirements (Ubuntu 24.04 host or build/Dockerfile): mmdebstrap squashfs-tools xorriso
# grub-efi-amd64-bin grub-pc-bin mtools dosfstools gnupg curl jq docker (for image seeds).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGES=(rootfs packages customize pool squashfs iso)

# ---------------------------------------------------------------------------
# configuration: config/build.env < config/build.local.env < environment
# ---------------------------------------------------------------------------
load_env() {
	local f=$1 k v
	[ -f "$f" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%#*}
		[[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
		k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
		v=${v%"${v##*[![:space:]]}"}                      # trim trailing spaces
		case "$v" in \"*\") v=${v#\"}; v=${v%\"} ;; \'*\') v=${v#\'}; v=${v%\'} ;; esac   # strip quotes
		[ -z "${!k+x}" ] && export "$k=$v" || true
	done < "$f"
}
load_env "$ROOT/config/build.local.env"
load_env "$ROOT/config/build.env"

OUT=${OUT:-$ROOT/out}
WORK=$OUT/work
ROOTFS=$WORK/rootfs
ISO_DIR=$WORK/iso
POOL=$OUT/pool
SEED=$OUT/seed
BUILD_ID=${BUILD_ID:-$(date -u +%Y%m%d-%H%M)-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)}
KEYRING=${KEYRING:-/usr/share/keyrings/ubuntu-archive-keyring.gpg}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
pkgs() { sed -e 's/#.*//' -e 's/[[:space:]]//g' "$@" | grep -v '^$' | sort -u; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
for t in mmdebstrap mksquashfs xorriso grub-mkrescue mformat curl gpg jq openssl git; do
	command -v "$t" >/dev/null || die "missing tool: $t"
done

# ---------------------------------------------------------------------------
# chroot helpers
# ---------------------------------------------------------------------------
MOUNTED=0
chroot_up() {
	[ "$MOUNTED" = 1 ] && return
	mount -t proc proc "$ROOTFS/proc"
	mount --rbind /sys "$ROOTFS/sys"; mount --make-rslave "$ROOTFS/sys"
	mount --rbind /dev "$ROOTFS/dev"; mount --make-rslave "$ROOTFS/dev"
	mount -t tmpfs tmpfs "$ROOTFS/run"
	mkdir -p "$ROOTFS/run/lock"
	MOUNTED=1
}
chroot_down() {
	[ "$MOUNTED" = 1 ] || return 0
	umount -l "$ROOTFS/run" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc" 2>/dev/null || true
	MOUNTED=0
}
trap chroot_down EXIT
in_chroot() {
	chroot_up
	local envs=(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive)
	for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
		[ -n "${!v:-}" ] && envs+=("$v=${!v}")
	done
	chroot "$ROOTFS" /usr/bin/env -i "${envs[@]}" "$@"
}
apt_chroot() { in_chroot apt-get -y -q -o Dpkg::Options::=--force-confnew "$@"; }

# Extra CA for build-time HTTPS proxies (e.g. CI sandboxes). Never ships in the image.
build_ca_on() {
	[ -n "${BUILD_EXTRA_CA_BUNDLE:-}" ] || return 0
	cp "$BUILD_EXTRA_CA_BUNDLE" "$ROOTFS/usr/local/share/ca-certificates/zz-build-proxy.crt"
	in_chroot update-ca-certificates >/dev/null 2>&1 || true
}
build_ca_off() {
	rm -f "$ROOTFS/usr/local/share/ca-certificates/zz-build-proxy.crt"
	in_chroot update-ca-certificates --fresh >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# stage: rootfs  (essential system from the Ubuntu archive)
# ---------------------------------------------------------------------------
stage_rootfs() {
	log "stage rootfs: mmdebstrap $UBUNTU_SUITE minbase"
	chroot_down
	rm -rf "$ROOTFS"; mkdir -p "$WORK"
	echo "$BUILD_ID" > "$WORK/build-id"
	[ -f "$KEYRING" ] || die "keyring $KEYRING not found (apt install ubuntu-keyring)"
	mmdebstrap --mode=root --variant=minbase --architectures="$ARCH" \
		--components=main,universe --keyring="$KEYRING" \
		--aptopt='APT::Install-Recommends "false"' \
		--dpkgopt='path-exclude=/usr/share/man/*' \
		--dpkgopt='path-exclude=/usr/share/doc/*' \
		--dpkgopt='path-include=/usr/share/doc/*/copyright' \
		--dpkgopt='path-exclude=/usr/share/info/*' \
		--dpkgopt='path-exclude=/usr/share/locale/*' \
		--dpkgopt='path-include=/usr/share/locale/en*' \
		--dpkgopt='path-include=/usr/share/locale/locale.alias' \
		--skip=cleanup/apt --include=apt,ca-certificates \
		"$UBUNTU_SUITE" "$ROOTFS" \
		"deb $UBUNTU_MIRROR $UBUNTU_SUITE main universe" \
		"deb $UBUNTU_MIRROR $UBUNTU_SUITE-updates main universe" \
		"deb $UBUNTU_MIRROR $UBUNTU_SUITE-security main universe"
}

# Essential packages are extracted by mmdebstrap without keeping the .deb; fetch
# every installed package that is not in the pool yet so pool/main == the image.
complete_pool() {
	local missing=() pkg ver arch f
	while read -r pkg ver arch; do
		f="${pkg}_${ver//:/%3a}_${arch}.deb"
		[ -f "$POOL/main/$f" ] || missing+=("$pkg=$ver")
	done < <(in_chroot dpkg-query -W -f='${Package} ${Version} ${Architecture}\n')
	[ ${#missing[@]} -gt 0 ] || return 0
	log "downloading ${#missing[@]} installed packages missing from the pool"
	in_chroot sh -c "cd /var/cache/apt/archives && apt-get download -q $(printf '%s ' "${missing[@]}")" \
		|| warn "some packages could not be downloaded for the pool"
	find "$ROOTFS/var/cache/apt/archives" -maxdepth 1 -name '*.deb' -exec mv -f {} "$POOL/main/" \;
}

# ---------------------------------------------------------------------------
# stage: packages  (kernel, base, docker, gui, tools installed inside the chroot)
# ---------------------------------------------------------------------------
stage_packages() {
	log "stage packages"
	[ -d "$ROOTFS/etc" ] || die "rootfs missing, run stage rootfs first"
	mkdir -p "$ROOTFS/etc/apt/keyrings" "$ROOTFS/usr/local/share/ca-certificates"
	cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf.build"; rm -f "$ROOTFS/etc/resolv.conf"; cp "$ROOTFS/etc/resolv.conf.build" "$ROOTFS/etc/resolv.conf"
	printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"; chmod +x "$ROOTFS/usr/sbin/policy-rc.d"
	install -m644 "$ROOT/overlay/etc/apt/apt.conf.d/99-lite" "$ROOTFS/etc/apt/apt.conf.d/99-lite"
	build_ca_on

	# build-time sources: Ubuntu archive + third-party repos (customize replaces them with Nexus only)
	rm -f "$ROOTFS/etc/apt/sources.list" "$ROOTFS"/etc/apt/sources.list.d/*
	cat > "$ROOTFS/etc/apt/sources.list.d/build-ubuntu.list" <<-SRC
	deb $UBUNTU_MIRROR $UBUNTU_SUITE main universe
	deb $UBUNTU_MIRROR $UBUNTU_SUITE-updates main universe
	deb $UBUNTU_MIRROR $UBUNTU_SUITE-security main universe
	SRC
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "$ROOTFS/etc/apt/keyrings/docker.gpg" --yes
	curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o "$ROOTFS/etc/apt/keyrings/microsoft.gpg" --yes
	curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o "$ROOTFS/etc/apt/keyrings/google.gpg" --yes
	cat > "$ROOTFS/etc/apt/sources.list.d/build-thirdparty.list" <<-SRC
	deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_SUITE stable
	deb [arch=$ARCH signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main
	deb [arch=$ARCH signed-by=/etc/apt/keyrings/google.gpg] https://dl.google.com/linux/chrome/deb/ stable main
	SRC

	# debconf answers
	in_chroot debconf-set-selections <<-DEB
	locales locales/default_environment_locale select $LOCALE
	locales locales/locales_to_be_generated multiselect $LOCALE UTF-8
	tzdata tzdata/Areas select ${TIMEZONE%%/*}
	tzdata tzdata/Zones/${TIMEZONE%%/*} select ${TIMEZONE#*/}
	krb5-config krb5-config/default_realm string ${AD_REALM:-EXAMPLE.COM}
	krb5-config krb5-config/kerberos_servers string ${AD_KDC:-}
	krb5-config krb5-config/admin_server string
	DEB
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$ROOTFS/etc/localtime"
	echo "$TIMEZONE" > "$ROOTFS/etc/timezone"
	mkdir -p "$ROOTFS/etc/default"
	echo 'repo_add_once="false"' > "$ROOTFS/etc/default/google-chrome"
	cat > "$ROOTFS/etc/default/grub" <<-GRUB
	GRUB_DEFAULT=0
	GRUB_TIMEOUT=1
	GRUB_TIMEOUT_STYLE=hidden
	GRUB_DISTRIBUTOR="ubuntu-lite"
	GRUB_CMDLINE_LINUX_DEFAULT="quiet"
	GRUB_CMDLINE_LINUX="${SERIAL_CONSOLE_CMDLINE:-}"
	GRUB_DISABLE_OS_PROBER=true
	GRUB
	# our initramfs boot script must exist before the kernel builds its initrd
	mkdir -p "$ROOTFS/etc/initramfs-tools/scripts" "$ROOTFS/etc/initramfs-tools/hooks"
	install -m644 "$ROOT/overlay/etc/initramfs-tools/scripts/lite" "$ROOTFS/etc/initramfs-tools/scripts/lite"
	install -m755 "$ROOT/overlay/etc/initramfs-tools/hooks/lite" "$ROOTFS/etc/initramfs-tools/hooks/lite"

	apt_chroot update
	# kernel first (grub not yet present, so the kernel postinst does not run update-grub in the chroot)
	apt_chroot install initramfs-tools "linux-image-$KERNEL_FLAVOUR"
	local kver
	kver=$(ls "$ROOTFS"/boot/vmlinuz-* | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)
	[ -n "$kver" ] || die "kernel not installed"
	echo "$kver" > "$WORK/kver"
	# older kernels split desktop drivers into linux-modules-extra; 7.x HWE kernels ship them in linux-modules
	local extra_pkg=""
	if in_chroot apt-cache show "linux-modules-extra-$kver" >/dev/null 2>&1; then
		extra_pkg="linux-modules-extra-$kver"
		apt_chroot install "$extra_pkg"
	fi

	local list
	list=$(pkgs "$ROOT"/config/packages/base.txt "$ROOT"/config/packages/docker.txt "$ROOT"/config/packages/gui.txt "$ROOT"/config/packages/tools.txt "$ROOT"/config/packages/corporate.txt)
	case "${FIRMWARE_MODE:-select}" in
		full) list="$list"$'\n'"linux-firmware" ;;
		select) list="$list"$'\n'"$(pkgs "$ROOT/config/packages/firmware.txt")" ;;
		none) ;;
		*) die "FIRMWARE_MODE must be select, full or none" ;;
	esac
	list=$(echo "$list" | grep -v '^$' | sort -u)
	log "installing $(echo "$list" | wc -l) packages"
	# shellcheck disable=SC2086
	apt_chroot install $list
	# shellcheck disable=SC2086
	in_chroot apt-mark manual $list "linux-image-$KERNEL_FLAVOUR" $extra_pkg >/dev/null
	# the lists are authoritative: purge manually installed packages that were removed from them
	local unwanted
	unwanted=$(comm -23 <(in_chroot apt-mark showmanual | sort -u) \
		<(printf '%s\n' $list "linux-image-$KERNEL_FLAVOUR" $extra_pkg "linux-image-$kver" "linux-modules-$kver" apt ca-certificates | sort -u) \
		| grep -vE '^(linux-(image|modules|headers)-|initramfs-tools|apt$|ca-certificates$)' || true)
	if [ -n "$unwanted" ]; then
		log "purging packages no longer listed: $(echo $unwanted | tr '\n' ' ')"
		# shellcheck disable=SC2086
		apt_chroot purge $unwanted
	fi
	apt_chroot autoremove --purge

	# collect every deb that went into the image
	mkdir -p "$POOL/main"
	find "$ROOTFS/var/cache/apt/archives" -maxdepth 1 -name '*.deb' -exec mv -f {} "$POOL/main/" \;
	complete_pool

	# extras: downloaded only, for Nexus
	rm -rf "$POOL/extra"; mkdir -p "$POOL/extra"
	local extra
	extra=$(pkgs "$ROOT/config/packages/nexus-extra.txt")
	if [ -n "$extra" ]; then
		# shellcheck disable=SC2086
		apt_chroot install --download-only $extra || warn "some nexus-extra packages failed to download"
		find "$ROOTFS/var/cache/apt/archives" -maxdepth 1 -name '*.deb' -exec mv -f {} "$POOL/extra/" \;
	fi
	build_ca_off
	log "packages done: $(ls "$POOL/main" | wc -l) debs in pool/main, $(ls "$POOL/extra" | wc -l) in pool/extra"
}

# ---------------------------------------------------------------------------
# stage: customize  (overlay, users, nexus, seeds, trimming)
# ---------------------------------------------------------------------------
fetch_github_binaries() {
	[ "${BUNDLE_GITHUB_BINARIES:-1}" = 1 ] || return 0
	mkdir -p "$SEED/bin"
	while IFS='|' read -r name repo template inner prefix extra; do
		[ -z "$name" ] && continue
		local ext file tmp bin
		case "$template" in
			*.tar.gz|*.tgz) ext=tar.gz ;; *.tar.xz) ext=tar.xz ;; *.zip) ext=zip ;; *) ext=bin ;;
		esac
		file="$SEED/bin/$name.$ext"
		if [ ! -s "$file" ]; then
			local tag ver asset url got=0 line
			# candidate tags newest first; a tag without the asset (nightly, unreleased) falls back to the previous one
			while read -r ver tag; do
				asset=${template//\{tag\}/$tag}; asset=${asset//\{ver\}/$ver}
				url="https://github.com/$repo/releases/download/$tag/$asset"
				if curl -fsSL -o "$file" "$url" 2>/dev/null; then log "fetched $name $ver"; echo "$url" > "$SEED/bin/$name.url"; got=1; break; fi
			done < <(git ls-remote --tags --refs "https://github.com/$repo" 2>/dev/null | sed 's#.*refs/tags/##' \
				| { if [ -n "$prefix" ]; then grep -F "$prefix" | grep "^$prefix"; else grep -E '^v?[0-9]+\.[0-9]+'; fi; } \
				| while read -r t; do v=${t#"$prefix"}; v=${v#v}; echo "$v $t"; done | grep -Ev '[a-z]' | sort -Vr | head -n 6)
			[ $got = 1 ] || { warn "no downloadable release asset for $name ($repo, $template)"; rm -f "$file"; continue; }
		fi
		tmp=$(mktemp -d)
		case "$ext" in
			tar.gz) tar -xzf "$file" -C "$tmp" ;;
			tar.xz) tar -xJf "$file" -C "$tmp" ;;
			zip) unzip -q "$file" -d "$tmp" ;;
			bin) cp "$file" "$tmp/$inner" ;;
		esac
		bin=$(find "$tmp" -type f -name "$(basename "$inner")" | head -n1)
		[ -n "$bin" ] || { warn "$inner not found inside $file"; rm -rf "$tmp"; continue; }
		install -m755 "$bin" "$ROOTFS/usr/local/bin/$name"
		if [ -n "$extra" ]; then
			local src=${extra%%:*} dst=${extra#*:} srcdir
			srcdir=$(find "$tmp" -type d -name "$src" | head -n1)
			[ -n "$srcdir" ] && { rm -rf "$ROOTFS$dst"; mkdir -p "$(dirname "$ROOTFS$dst")"; cp -a "$srcdir" "$ROOTFS$dst"; } || warn "$src not found in $file"
		fi
		rm -rf "$tmp"
	done < <(sed -e 's/#.*//' "$ROOT/config/github-binaries.txt" | grep -v '^[[:space:]]*$')
}

# Ask the marketplace for the newest stable version, preferring a linux-x64 build.
vsix_version() { # publisher.name -> "version targetPlatform|universal"
	curl -fsS -X POST "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" \
		-H 'Content-Type: application/json' -H 'Accept: application/json;api-version=3.0-preview.1' \
		-d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"$1\"}]}],\"flags\":103}" \
	| jq -r '[.results[0].extensions[0].versions[]
		| select(((.properties // []) | map(select(.key=="Microsoft.VisualStudio.Code.PreRelease" and .value=="true")) | length) == 0)
		| select(.targetPlatform=="linux-x64" or .targetPlatform==null)]
		| sort_by(.version | split(".") | map(tonumber? // 0)) | reverse | .[0]
		| "\(.version) \(.targetPlatform // "universal")"'
}

fetch_vsix() {
	[ "${BUNDLE_VSCODE_EXTENSIONS:-1}" = 1 ] || return 0
	mkdir -p "$SEED/vsix" "$ROOTFS/usr/share/ubuntu-lite/vsix"
	local ext pub name ver tp url f info
	for ext in $(pkgs "$ROOT/config/vscode-extensions.txt"); do
		ver=${ext#*@}; [ "$ver" = "$ext" ] && ver=""
		ext=${ext%@*}; pub=${ext%%.*}; name=${ext#*.}
		tp=universal
		if [ -z "$ver" ]; then
			info=$(vsix_version "$ext" || true)
			ver=${info%% *}; tp=${info##* }
			[ -n "$ver" ] && [ "$ver" != null ] || { warn "cannot resolve version of $ext"; continue; }
		fi
		f="$SEED/vsix/$pub.$name-$ver.vsix"
		if [ ! -s "$f" ]; then
			log "fetching VS Code extension $ext $ver ($tp)"
			url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$pub/vsextensions/$name/$ver/vspackage"
			[ "$tp" != universal ] && url="$url?targetPlatform=$tp"
			curl -fsSL --compressed -o "$f" "$url" || { warn "could not download $ext"; rm -f "$f"; continue; }
		fi
		cp "$f" "$ROOTFS/usr/share/ubuntu-lite/vsix/"
	done
}

fetch_docker_images() {
	[ "${BUNDLE_DOCKER_IMAGES:-1}" = 1 ] || return 0
	docker info >/dev/null 2>&1 || { warn "docker daemon not reachable, skipping image seeds"; return 0; }
	mkdir -p "$SEED/docker"
	local img f
	for img in $(pkgs "$ROOT/config/docker-images.txt"); do
		f="$SEED/docker/$(echo "$img" | tr '/:' '__').tar"
		[ -s "$f" ] && continue
		log "pulling $img"
		if docker pull -q --platform "linux/$ARCH" "$img" >/dev/null && docker save -o "$f" "$img"; then :; else
			warn "could not bundle $img"; rm -f "$f"
		fi
	done
}

stage_customize() {
	log "stage customize"
	[ -f "$WORK/kver" ] || die "run stage packages first"
	local kver; kver=$(cat "$WORK/kver")
	build_ca_on

	# overlay
	cp -a "$ROOT/overlay/." "$ROOTFS/"

	# image metadata + runtime config for the installer
	mkdir -p "$ROOTFS/usr/share/ubuntu-lite" "$ROOTFS/etc/ubuntu-lite" "$ROOTFS/usr/share/doc/ubuntu-lite"
	echo "$BUILD_ID" > "$ROOTFS/etc/ubuntu-lite/build-id"
	cat > "$ROOTFS/usr/share/ubuntu-lite/lite.conf" <<-CONF
	BUILD_ID=$BUILD_ID
	USERNAME=$USERNAME
	SWAP_SIZE=$SWAP_SIZE
	CONF
	# site defaults (Nexus, AD, OWA); changed later on the machine with `sudo lite-setup`
	mkdir -p "$ROOTFS/etc/ubuntu-lite"
	{
		echo "# defaults from config/build.env at build time; run 'sudo lite-setup' to change"
		for k in NEXUS_URL NEXUS_APT_REPO NEXUS_DOCKER_REGISTRY NEXUS_DOCKER_INSECURE NEXUS_IP AD_REALM AD_DOMAIN AD_KDC OWA_URL EXTRA_HOSTS; do
			printf '%s=%q\n' "$k" "${!k:-}"
		done
	} > "$ROOTFS/etc/ubuntu-lite/site.conf"
	cp "$ROOT/README.md" "$ROOT/AGENTS.md" "$ROOT"/docs/*.md "$ROOT"/docs/*.json "$ROOTFS/usr/share/doc/ubuntu-lite/" 2>/dev/null || true
	install -m755 "$ROOT/scripts/nexus-upload.sh" "$ROOTFS/usr/lib/ubuntu-lite/nexus-upload.sh"
	ln -sf /usr/lib/ubuntu-lite/nexus-upload.sh "$ROOTFS/usr/local/bin/lite-nexus-upload"

	# identity, locale, console
	echo "ubuntu-lite" > "$ROOTFS/etc/hostname"
	printf '127.0.0.1 localhost\n127.0.1.1 ubuntu-lite\n::1 localhost ip6-localhost ip6-loopback\n' > "$ROOTFS/etc/hosts"
	sed -i "s/^# *$LOCALE UTF-8/$LOCALE UTF-8/" "$ROOTFS/etc/locale.gen"
	grep -q "^$LOCALE UTF-8" "$ROOTFS/etc/locale.gen" || echo "$LOCALE UTF-8" >> "$ROOTFS/etc/locale.gen"
	in_chroot locale-gen >/dev/null
	echo "LANG=$LOCALE" > "$ROOTFS/etc/default/locale"
	printf 'KEYMAP=%s\n' "$KEYMAP" > "$ROOTFS/etc/vconsole.conf"
	printf 'XKBMODEL="pc105"\nXKBLAYOUT="%s"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' "$KEYMAP" > "$ROOTFS/etc/default/keyboard"

	# user
	for g in docker video audio render plugdev; do in_chroot getent group "$g" >/dev/null || in_chroot groupadd "$g"; done
	if ! in_chroot id "$USERNAME" >/dev/null 2>&1; then
		in_chroot useradd -m -s /bin/bash -G sudo,docker,video,audio,render,plugdev "$USERNAME"
	fi
	# re-runs of this stage must still pick up new /etc/skel files for the existing user
	in_chroot sh -c "cp -a /etc/skel/. /home/$USERNAME/ && chown -R $USERNAME:$USERNAME /home/$USERNAME"
	in_chroot usermod -p "$(openssl passwd -6 "$USER_PASSWORD")" "$USERNAME"
	in_chroot chage -d 0 "$USERNAME"
	in_chroot passwd -l root >/dev/null
	local keys; keys=$(grep -v '^[[:space:]]*#' "$ROOT/config/authorized_keys" | grep -v '^[[:space:]]*$' || true)
	if [ -n "$keys" ]; then
		mkdir -p "$ROOTFS/home/$USERNAME/.ssh"
		echo "$keys" > "$ROOTFS/home/$USERNAME/.ssh/authorized_keys"
		chmod 700 "$ROOTFS/home/$USERNAME/.ssh"; chmod 600 "$ROOTFS/home/$USERNAME/.ssh/authorized_keys"
		in_chroot chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
		echo "PasswordAuthentication no" >> "$ROOTFS/etc/ssh/sshd_config.d/10-lite.conf"
	else
		warn "config/authorized_keys has no keys: sshd will accept password login"
		echo "PasswordAuthentication yes" >> "$ROOTFS/etc/ssh/sshd_config.d/10-lite.conf"
	fi
	if [ "${AUTOLOGIN:-0}" = 1 ]; then
		mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
		printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$USERNAME" \
			> "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf"
	fi


	# office CA, then Nexus/AD/OWA via the same tool the user runs after install
	local ca
	for ca in "$ROOT"/config/ca/*.crt; do [ -f "$ca" ] && cp "$ca" "$ROOTFS/usr/local/share/ca-certificates/"; done
	in_chroot update-ca-certificates >/dev/null
	mkdir -p "$ROOTFS/etc/apt/keyrings"
	if [ -f "$ROOT/config/nexus/apt-signing.pub.asc" ]; then
		cp "$ROOT/config/nexus/apt-signing.pub.asc" "$ROOTFS/etc/apt/keyrings/nexus-apt.asc"
	else
		warn "config/nexus/apt-signing.pub.asc missing (run build/keys.sh); Nexus apt source will be marked trusted=yes"
	fi
	in_chroot /usr/lib/ubuntu-lite/lite-setup --apply --offline >/dev/null

	# services
	in_chroot systemctl enable ssh docker containerd nftables systemd-networkd systemd-resolved lite-installer lite-firstboot lite-seed-images >/dev/null 2>&1
	in_chroot systemctl mask apt-daily.timer apt-daily-upgrade.timer motd-news.timer e2scrub_all.timer systemd-networkd-wait-online.service >/dev/null 2>&1 || true
	in_chroot systemctl disable getty@tty7.service >/dev/null 2>&1 || true
	ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
	rm -f "$ROOTFS/etc/resolv.conf.build"

	# seeds
	fetch_github_binaries
	fetch_vsix
	fetch_docker_images
	build_ca_off

	# trim
	in_chroot apt-get clean
	rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* \
		"$ROOTFS"/root/.bash_history "$ROOTFS"/root/.cache "$ROOTFS"/var/cache/debconf/*-old "$ROOTFS"/var/lib/dpkg/*-old \
		"$ROOTFS"/usr/share/doc/*/changelog* "$ROOTFS"/usr/sbin/policy-rc.d "$ROOTFS"/etc/ssh/ssh_host_* \
		"$ROOTFS"/etc/cron.daily/google-chrome "$ROOTFS"/opt/google/chrome/cron
	find "$ROOTFS/var/log" -type f -exec truncate -s0 {} +
	: > "$ROOTFS/etc/machine-id"
	rm -f "$ROOTFS/var/lib/dbus/machine-id"

	log "regenerating initramfs for $kver"
	if [ -f "$ROOTFS/boot/initrd.img-$kver" ]; then
		in_chroot update-initramfs -u -k "$kver" >/dev/null
	else
		in_chroot update-initramfs -c -k "$kver" >/dev/null
	fi
	[ -s "$ROOTFS/boot/initrd.img-$kver" ] || die "initramfs was not generated"

	# report
	{
		echo "build: $BUILD_ID  kernel: $kver"
		echo "rootfs: $(du -sh "$ROOTFS" | cut -f1)"
		echo; echo "largest packages (MB):"
		in_chroot dpkg-query -W -f='${Installed-Size}\t${Package}\n' | sort -n | tail -n 30 | awk '{printf "%6.0f  %s\n", $1/1024, $2}'
	} > "$OUT/size-report.txt"
	chroot_down
	cat "$OUT/size-report.txt"
}

# ---------------------------------------------------------------------------
# stage: pool  (apt index for the on-ISO pool so it is usable from a USB too)
# ---------------------------------------------------------------------------
stage_pool() {
	log "stage pool: indexing $(find "$POOL" -name '*.deb' | wc -l) debs"
	command -v apt-ftparchive >/dev/null || { warn "apt-ftparchive missing (apt-utils), pool index skipped"; return 0; }
	(cd "$POOL" && apt-ftparchive packages . | gzip -9 > Packages.gz)
}

# ---------------------------------------------------------------------------
# stage: squashfs / iso
# ---------------------------------------------------------------------------
stage_squashfs() {
	log "stage squashfs"
	chroot_down
	rm -f "$WORK/filesystem.squashfs"
	mksquashfs "$ROOTFS" "$WORK/filesystem.squashfs" -comp xz -b 1M -Xbcj x86 -noappend -quiet -no-progress
	ls -lh "$WORK/filesystem.squashfs"
}

stage_iso() {
	log "stage iso"
	local kver; kver=$(cat "$WORK/kver")
	local iso="$OUT/$IMAGE_NAME-$BUILD_ID.iso"
	rm -rf "$ISO_DIR"; mkdir -p "$ISO_DIR/boot/grub" "$ISO_DIR/lite" "$ISO_DIR/nexus"
	cp "$ROOTFS/boot/vmlinuz-$kver" "$ISO_DIR/lite/vmlinuz"
	cp "$ROOTFS/boot/initrd.img-$kver" "$ISO_DIR/lite/initrd.img"
	ln -f "$WORK/filesystem.squashfs" "$ISO_DIR/lite/filesystem.squashfs" 2>/dev/null || cp "$WORK/filesystem.squashfs" "$ISO_DIR/lite/"
	jq -n --arg id "$BUILD_ID" --arg k "$kver" --arg s "$UBUNTU_SUITE" --arg d "$(date -u +%FT%TZ)" \
		'{build_id:$id, kernel:$k, suite:$s, built_at:$d}' > "$ISO_DIR/lite/build.json"
	cp -al "$POOL" "$ISO_DIR/pool" 2>/dev/null || cp -a "$POOL" "$ISO_DIR/pool"
	[ -d "$SEED" ] && { cp -al "$SEED" "$ISO_DIR/seed" 2>/dev/null || cp -a "$SEED" "$ISO_DIR/seed"; }
	cp "$ROOT/scripts/nexus-upload.sh" "$ROOT/docs/nexus-setup.md" "$ROOT/docs/airgap-workflow.md" "$ISO_DIR/nexus/" 2>/dev/null || true
	[ -f "$ROOT/config/nexus/apt-signing.pub.asc" ] && cp "$ROOT/config/nexus/apt-signing.pub.asc" "$ISO_DIR/nexus/"

	local cmdline="boot=lite console=ttyS0,115200n8 console=tty1"
	cat > "$ISO_DIR/boot/grub/grub.cfg" <<-CFG
	set timeout=5
	set default=0
	insmod all_video
	set gfxpayload=keep
	menuentry "Install ubuntu-lite ($BUILD_ID) - automatic, wipes the internal disk" {
		linux /lite/vmlinuz $cmdline lite.install=1 quiet
		initrd /lite/initrd.img
	}
	menuentry "Reinstall ubuntu-lite - force, even if already installed" {
		linux /lite/vmlinuz $cmdline lite.install=1 lite.force=1 quiet
		initrd /lite/initrd.img
	}
	menuentry "Live system (no install, rescue)" {
		linux /lite/vmlinuz $cmdline
		initrd /lite/initrd.img
	}
	menuentry "Install with verbose kernel output" {
		linux /lite/vmlinuz $cmdline lite.install=1
		initrd /lite/initrd.img
	}
	CFG
	rm -f "$iso"
	grub-mkrescue -o "$iso" "$ISO_DIR" -- -volid UBUNTU_LITE >/dev/null 2>&1 \
		|| grub-mkrescue -o "$iso" "$ISO_DIR" -- -volid UBUNTU_LITE
	(cd "$OUT" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
	ln -sf "$(basename "$iso")" "$OUT/$IMAGE_NAME-latest.iso"
	log "ISO ready: $iso ($(du -h "$iso" | cut -f1))"
}

# ---------------------------------------------------------------------------
FROM=""; ONLY=""
while [ $# -gt 0 ]; do
	case "$1" in
		--from) FROM=$2; shift ;;
		--only) ONLY=$2; shift ;;
		-h|--help) sed -n '2,8p' "$0"; exit 0 ;;
		*) die "unknown option $1" ;;
	esac
	shift
done
# a resumed or partial run keeps the build id of the rootfs it continues from
{ [ -n "$FROM" ] || [ -n "$ONLY" ]; } && [ -f "$WORK/build-id" ] && BUILD_ID=$(cat "$WORK/build-id")
mkdir -p "$OUT" "$WORK"
run=${FROM:-rootfs}; [ -z "$FROM" ] && run=rootfs
started=0
for s in "${STAGES[@]}"; do
	if [ -n "$ONLY" ]; then [ "$s" = "$ONLY" ] || continue; fi
	[ "$s" = "$run" ] && started=1
	[ $started = 1 ] || [ -n "$ONLY" ] || continue
	"stage_$s"
done
chroot_down
log "done"
