#!/bin/bash
# Upload the ISO's offline content into the office Nexus (OSS).
#   apt   pool/**/*.deb        -> apt (hosted) repository   NEXUS_APT_REPO
#   docker seed/docker/*.tar   -> docker (hosted) registry  NEXUS_DOCKER_REGISTRY (as library/<name> so registry-mirrors works)
#   raw   seed/vsix, seed/bin, the ISO itself -> raw (hosted) repository NEXUS_RAW_REPO under lite/
#
# Usage (on any machine that can reach Nexus, e.g. a freshly installed ubuntu-lite box with the USB mounted):
#   sudo mount /dev/sdb /mnt
#   NEXUS_USER=admin lite-nexus-upload --src /mnt all          # or: apt | docker | raw
# Env: NEXUS_URL NEXUS_USER NEXUS_PASS NEXUS_APT_REPO NEXUS_RAW_REPO NEXUS_DOCKER_REGISTRY
#      (defaults come from /usr/share/ubuntu-lite/lite.conf when present)
set -euo pipefail
[ -f /usr/share/ubuntu-lite/lite.conf ] && { set -a; . /usr/share/ubuntu-lite/lite.conf; set +a; }
NEXUS_URL=${NEXUS_URL:?set NEXUS_URL}
NEXUS_APT_REPO=${NEXUS_APT_REPO:-apt-lite}
NEXUS_RAW_REPO=${NEXUS_RAW_REPO:-raw-lite}
NEXUS_DOCKER_REGISTRY=${NEXUS_DOCKER_REGISTRY:-}
SRC=.
WHAT=all
while [ $# -gt 0 ]; do
	case "$1" in
		--src) SRC=$2; shift ;;
		apt|docker|raw|all) WHAT=$1 ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "unknown arg $1"; exit 1 ;;
	esac; shift
done
[ -d "$SRC" ] || { echo "source dir $SRC not found"; exit 1; }
NEXUS_USER=${NEXUS_USER:-admin}
if [ -z "${NEXUS_PASS:-}" ]; then read -rsp "Nexus password for $NEXUS_USER: " NEXUS_PASS; echo; fi
AUTH=(-u "$NEXUS_USER:$NEXUS_PASS")
ok=0; fail=0; skip=0

upload_apt() {
	local repo="$NEXUS_URL/service/rest/v1/components?repository=$NEXUS_APT_REPO"
	local n; n=$(find "$SRC/pool" -name '*.deb' | wc -l)
	echo "== apt: uploading $n debs to $NEXUS_APT_REPO"
	find "$SRC/pool" -name '*.deb' | sort | while read -r f; do
		code=$(curl -sS -o /tmp/nexus-up.out -w '%{http_code}' "${AUTH[@]}" -F "apt.asset=@$f" "$repo")
		case "$code" in
			204|200) echo "  ok   $(basename "$f")" ;;
			400) echo "  skip $(basename "$f") (already present)" ;;
			*) echo "  FAIL $(basename "$f") HTTP $code: $(head -c 200 /tmp/nexus-up.out)" ;;
		esac
	done
}

upload_docker() {
	[ -n "$NEXUS_DOCKER_REGISTRY" ] || { echo "NEXUS_DOCKER_REGISTRY not set, skipping docker"; return; }
	command -v docker >/dev/null || { echo "docker not installed here, skipping"; return; }
	echo "== docker: pushing images to $NEXUS_DOCKER_REGISTRY"
	echo "$NEXUS_PASS" | docker login "$NEXUS_DOCKER_REGISTRY" -u "$NEXUS_USER" --password-stdin
	for t in "$SRC"/seed/docker/*.tar; do
		[ -f "$t" ] || continue
		local img; img=$(docker load -i "$t" | sed -n 's/^Loaded image: //p' | head -n1)
		[ -n "$img" ] || { echo "  FAIL could not load $t"; continue; }
		local target
		case "$img" in */*) target="$NEXUS_DOCKER_REGISTRY/$img" ;; *) target="$NEXUS_DOCKER_REGISTRY/library/$img" ;; esac
		docker tag "$img" "$target"
		if docker push -q "$target" >/dev/null; then echo "  ok   $target"; else echo "  FAIL $target"; fi
		docker rmi "$target" >/dev/null 2>&1 || true
	done
}

upload_raw() {
	echo "== raw: uploading extras to $NEXUS_RAW_REPO/lite/"
	local f
	for f in "$SRC"/seed/vsix/*.vsix "$SRC"/seed/bin/*.tar.gz "$SRC"/nexus/apt-signing.pub.asc "$SRC"/*.iso; do
		[ -f "$f" ] || continue
		local sub; sub=$(basename "$(dirname "$f")"); [ "$sub" = "$(basename "$SRC")" ] && sub=iso
		code=$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" --upload-file "$f" "$NEXUS_URL/repository/$NEXUS_RAW_REPO/lite/$sub/$(basename "$f")")
		case "$code" in 201|200|204) echo "  ok   $sub/$(basename "$f")" ;; *) echo "  FAIL $sub/$(basename "$f") HTTP $code" ;; esac
	done
}

case "$WHAT" in
	apt) upload_apt ;;
	docker) upload_docker ;;
	raw) upload_raw ;;
	all) upload_apt; upload_docker; upload_raw ;;
esac
echo "done. Verify on a lite machine: sudo apt update && apt policy htop ; docker pull node:22-slim"
