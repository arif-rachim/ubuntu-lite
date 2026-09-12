#!/bin/bash
# ubuntu-lite unattended installer. Runs from the live ISO (boot=lite lite.install).
#   lite.disk=/dev/nvme0n1   choose target disk (default: largest internal disk)
#   lite.force=1             reinstall even if ubuntu-lite is already on the disk
#   lite.hostname=name       hostname (default: lite-<last 6 hex of MAC>)
set -euo pipefail

ISO=/run/lite/iso
SRC=/run/lite/ro
TARGET_MNT=/mnt/target
. /usr/share/ubuntu-lite/lite.conf

# Output goes to tty1; mirror it to the serial console when one is configured (QEMU tests, headless boxes).
if grep -q 'console=ttyS0' /proc/cmdline && [ -c /dev/ttyS0 ]; then exec > >(tee /dev/ttyS0) 2>&1; fi
kmsg() { echo "<3>lite: $*" > /dev/kmsg 2>/dev/null || true; }
log()  { printf '\n\033[1;32m[lite] %s\033[0m\n' "$*"; kmsg "$*"; }
warn() { printf '\033[1;33m[lite] %s\033[0m\n' "$*"; kmsg "WARNING: $*"; }
die()  { printf '\n\033[1;31m[lite] ERROR: %s\033[0m\n' "$*"; kmsg "ERROR: $*"; echo "Dropping to a shell for debugging (type 'reboot' to restart)."; exec /bin/bash; }
opt()  { tr ' ' '\n' </proc/cmdline | sed -n "s/^$1=//p" | tail -n1; }

log "ubuntu-lite installer, build ${BUILD_ID}"
[ -d "$ISO/lite" ] || die "ISO not mounted at $ISO"

# ---- 1. pick the target disk -------------------------------------------------
boot_dev=$(findmnt -no SOURCE "$ISO" || true)
boot_disk=""
if [ -n "$boot_dev" ]; then
	boot_disk=$(lsblk -no PKNAME "$boot_dev" 2>/dev/null | head -n1 || true)
	[ -z "$boot_disk" ] && boot_disk=$(basename "$boot_dev")
fi

TARGET=$(opt lite.disk)
if [ -z "$TARGET" ]; then
	# candidates: whole disks, not removable, not USB, not the boot medium; pick the largest
	TARGET=$(lsblk -dnpb -P -o NAME,TYPE,RM,TRAN,SIZE | while read -r line; do
		eval "$line"
		[ "$TYPE" = disk ] && [ "$RM" = 0 ] && [ "$TRAN" != usb ] && [ "$NAME" != "/dev/$boot_disk" ] && echo "$SIZE $NAME"
	done | sort -n | tail -n1 | awk '{print $2}')
fi
[ -n "$TARGET" ] && [ -b "$TARGET" ] || die "no suitable internal disk found (pass lite.disk=/dev/xxx)"
log "target disk: $TARGET ($(lsblk -dno SIZE,MODEL "$TARGET" | tr -s ' '))"

# ---- 2. refuse to wipe an existing install unless forced ---------------------
if [ "$(opt lite.force)" != "1" ]; then
	for p in $(lsblk -nlpo NAME "$TARGET" | tail -n +2); do
		if [ "$(blkid -o value -s LABEL "$p" 2>/dev/null)" = "lite-root" ]; then
			mkdir -p /mnt/probe
			if mount -o ro "$p" /mnt/probe 2>/dev/null; then
				existing=$(cat /mnt/probe/etc/ubuntu-lite/build-id 2>/dev/null || echo unknown)
				umount /mnt/probe
				warn "ubuntu-lite (build $existing) is already installed on $p."
				warn "Remove the USB stick and reboot, or choose the 'Reinstall' entry to wipe it."
				warn "Powering off in 30 seconds."
				sleep 30
				systemctl poweroff
				exit 0
			fi
		fi
	done
fi

# ---- 3. partition + format ----------------------------------------------------
log "partitioning $TARGET (GPT: 512M EFI + ext4 root)"
swapoff -a 2>/dev/null || true
for p in $(lsblk -nlpo NAME "$TARGET" | tail -n +2); do umount -f "$p" 2>/dev/null || true; done
wipefs -af "$TARGET" >/dev/null
sgdisk --zap-all "$TARGET" >/dev/null
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:root "$TARGET" >/dev/null
blockdev --rereadpt "$TARGET" 2>/dev/null || true
udevadm settle --timeout=10 || true
case "$TARGET" in *nvme*|*mmcblk*|*loop*) P1="${TARGET}p1"; P2="${TARGET}p2" ;; *) P1="${TARGET}1"; P2="${TARGET}2" ;; esac
for i in $(seq 1 10); do [ -b "$P2" ] && break; sleep 1; done
[ -b "$P2" ] || die "partition $P2 did not appear"
mkfs.vfat -F32 -n EFI "$P1" >/dev/null
mkfs.ext4 -qF -L lite-root "$P2"
mkdir -p "$TARGET_MNT"
mount "$P2" "$TARGET_MNT"
mkdir -p "$TARGET_MNT/boot/efi"
mount "$P1" "$TARGET_MNT/boot/efi"

# ---- 4. copy the system ------------------------------------------------------
log "copying system to $P2 (this takes a few minutes)"
cp -a "$SRC/." "$TARGET_MNT/"
sync

# ---- 5. per-machine configuration --------------------------------------------
root_uuid=$(blkid -o value -s UUID "$P2")
efi_uuid=$(blkid -o value -s UUID "$P1")
cat > "$TARGET_MNT/etc/fstab" <<FSTAB
UUID=$root_uuid  /          ext4  defaults,noatime,errors=remount-ro  0 1
UUID=$efi_uuid   /boot/efi  vfat  umask=0077                          0 1
FSTAB

if [ "${SWAP_SIZE:-0}" != "0" ]; then
	log "creating ${SWAP_SIZE} swap file"
	fallocate -l "$SWAP_SIZE" "$TARGET_MNT/swapfile"
	chmod 600 "$TARGET_MNT/swapfile"
	mkswap -q "$TARGET_MNT/swapfile"
	echo "/swapfile  none  swap  sw  0 0" >> "$TARGET_MNT/etc/fstab"
fi

host=$(opt lite.hostname)
if [ -z "$host" ]; then
	mac=$(cat /sys/class/net/e*/address 2>/dev/null | head -n1 | tr -d ':' | tail -c 7)
	host="lite-${mac:-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' ')}"
fi
echo "$host" > "$TARGET_MNT/etc/hostname"
sed -i "/^127\.0\.1\.1/d" "$TARGET_MNT/etc/hosts"
echo "127.0.1.1 $host" >> "$TARGET_MNT/etc/hosts"
: > "$TARGET_MNT/etc/machine-id"
rm -f "$TARGET_MNT"/etc/ssh/ssh_host_*
rm -f "$TARGET_MNT/var/lib/ubuntu-lite/firstboot.done"
mkdir -p "$TARGET_MNT/etc/ubuntu-lite"
echo "$BUILD_ID" > "$TARGET_MNT/etc/ubuntu-lite/build-id"
date -u +%FT%TZ > "$TARGET_MNT/etc/ubuntu-lite/installed-at"

# ---- 6. bootloader -----------------------------------------------------------
log "installing GRUB (UEFI)"
for d in dev proc sys; do mount --bind "/$d" "$TARGET_MNT/$d"; done
mount -t efivarfs efivarfs "$TARGET_MNT/sys/firmware/efi/efivars" 2>/dev/null || true
# --removable writes EFI/BOOT/BOOTX64.EFI so every UEFI firmware boots it without NVRAM entries
chroot "$TARGET_MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
	--bootloader-id=ubuntu-lite --removable --recheck --no-nvram
# also try a proper NVRAM entry, harmless if it fails
chroot "$TARGET_MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
	--bootloader-id=ubuntu-lite --recheck 2>/dev/null || true
chroot "$TARGET_MNT" update-grub 2>&1 | grep -v "^Found" || true

# ---- 7. docker image seeds: loaded by lite-seed-images.service on first boot ------
if ls "$ISO"/seed/docker/*.tar >/dev/null 2>&1; then
	log "copying docker image seeds (loaded on first boot)"
	mkdir -p "$TARGET_MNT/var/lib/ubuntu-lite/seed"
	cp "$ISO"/seed/docker/*.tar "$TARGET_MNT/var/lib/ubuntu-lite/seed/"
fi

# ---- 8. finish ---------------------------------------------------------------
sync
umount "$TARGET_MNT/sys/firmware/efi/efivars" 2>/dev/null || true
for d in sys proc dev; do umount -l "$TARGET_MNT/$d"; done
umount "$TARGET_MNT/boot/efi"
umount "$TARGET_MNT"
log "installation complete: $host on $TARGET"
echo "Remove the USB stick now. Rebooting in 10 seconds."
sleep 10
systemctl reboot
