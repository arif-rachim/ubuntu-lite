#!/bin/bash
# Boot-test the ISO in QEMU (UEFI). Uses KVM when available, otherwise TCG (slow).
#   scripts/test-qemu.sh install [iso]   boot the ISO, run the unattended install onto a fresh virtual disk
#   scripts/test-qemu.sh boot            boot the installed virtual disk, wait for the login prompt
#   scripts/test-qemu.sh run             boot the disk interactively (serial console on this terminal)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT:-$ROOT/out}
DISK=${DISK:-$OUT/test-disk.qcow2}
LOG=${LOG:-$OUT/test-serial.log}
MEM=${MEM:-4096}
TIMEOUT=${TIMEOUT:-2400}
OVMF_CODE=$( { ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd 2>/dev/null || true; } | head -n1)
OVMF_VARS_SRC=$( { ls /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null || true; } | head -n1)
[ -n "$OVMF_CODE" ] || { echo "install ovmf"; exit 1; }
VARS=$OUT/test-ovmf-vars.fd
ACCEL="-accel tcg,thread=multi"; [ -e /dev/kvm ] && ACCEL="-accel kvm"
common=(qemu-system-x86_64 $ACCEL -cpu max -smp "$(nproc)" -m "$MEM" -machine q35
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$VARS"
	-drive if=none,id=hd,file="$DISK",format=qcow2 -device virtio-blk-pci,drive=hd,bootindex=1
	-device virtio-net-pci,netdev=n0 -netdev user,id=n0,hostfwd=tcp::2222-:22
	-device virtio-rng-pci -no-reboot -monitor unix:"$OUT/test-mon.sock",server,nowait)
powerdown() { # clean ACPI shutdown so first-boot writes reach the disk
	python3 - "$OUT/test-mon.sock" <<-'PY' 2>/dev/null || true
	import socket,sys,time
	s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.5); s.recv(4096)
	s.sendall(b"system_powerdown\n"); time.sleep(1); s.close()
	PY
	local i=0
	while kill -0 "$QPID" 2>/dev/null && [ $i -lt 180 ]; do sleep 2; i=$((i + 2)); done
	kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
}
# the ISO is presented as a USB stick, exactly like on real hardware
usb_iso() { echo -drive if=none,id=usb,file="$1",format=raw,readonly=on -device qemu-xhci -device usb-storage,drive=usb,bootindex=0; }

wait_for() { # pattern timeout
	local i=0
	while [ $i -lt "$2" ]; do
		grep -aq "$1" "$LOG" 2>/dev/null && return 0
		kill -0 "$QPID" 2>/dev/null || return 1
		sleep 5; i=$((i + 5))
	done
	return 1
}

case "${1:-}" in
	install)
		ISO=${2:-$OUT/ubuntu-lite-latest.iso}
		[ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }
		# Remaster with the serial port as primary console so the whole install is visible in $LOG.
		if [ -d "$OUT/work/iso/lite" ] && [ -z "${2:-}" ]; then
			D=$OUT/work/iso-test; rm -rf "$D"; mkdir -p "$D/boot/grub"
			cp -al "$OUT/work/iso/lite" "$OUT/work/iso/seed" "$D/" 2>/dev/null || cp -a "$OUT/work/iso/lite" "$OUT/work/iso/seed" "$D/"
			printf 'set timeout=1\nmenuentry "test" {\n linux /lite/vmlinuz boot=lite console=tty1 console=ttyS0,115200n8 lite.install=1\n initrd /lite/initrd.img\n}\n' > "$D/boot/grub/grub.cfg"
			ISO=$OUT/ubuntu-lite-test.iso
			grub-mkrescue -o "$ISO" "$D" -- -volid UBUNTU_LITE >/dev/null 2>&1 || { echo "grub-mkrescue failed"; exit 1; }
		fi
		rm -f "$DISK" "$LOG"; qemu-img create -q -f qcow2 "$DISK" 20G; cp "$OVMF_VARS_SRC" "$VARS"
		echo "installing from $ISO (log: $LOG)"
		"${common[@]}" -display none -serial "file:$LOG" $(usb_iso "$ISO") &
		QPID=$!
		if wait_for "installation complete" "$TIMEOUT"; then
			echo "PASS: installer finished"; wait $QPID || true; exit 0
		fi
		echo "FAIL: installer did not finish within ${TIMEOUT}s"; tail -n 40 "$LOG"; powerdown; exit 1 ;;
	boot)
		: > "$LOG"
		"${common[@]}" -display none -serial "file:$LOG" &
		QPID=$!
		if wait_for " login: " "$TIMEOUT"; then
			echo "PASS: installed system reached login prompt"; grep -a "login:" "$LOG" | head -n1
			wait_for "lite: seed images done" 900 && grep -a "lite: seed images done" "$LOG" | tail -n1 || echo "note: seed-images marker not seen"
			grep -a "lite: first boot setup done" "$LOG" >/dev/null && echo "PASS: first boot setup ran"
			powerdown; exit 0
		fi
		echo "FAIL: no login prompt"; tail -n 40 "$LOG"; powerdown; exit 1 ;;
	run)
		exec "${common[@]}" -display none -serial mon:stdio ;;
	*) sed -n '2,6p' "$0"; exit 1 ;;
esac
