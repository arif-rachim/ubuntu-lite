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
	-device virtio-rng-pci -no-reboot)
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
		rm -f "$DISK" "$LOG"; qemu-img create -q -f qcow2 "$DISK" 20G; cp "$OVMF_VARS_SRC" "$VARS"
		echo "installing from $ISO (log: $LOG)"
		"${common[@]}" -display none -serial "file:$LOG" $(usb_iso "$ISO") &
		QPID=$!
		if wait_for "installation complete" "$TIMEOUT"; then
			echo "PASS: installer finished"; wait $QPID || true; exit 0
		fi
		echo "FAIL: installer did not finish within ${TIMEOUT}s"; tail -n 40 "$LOG"; kill $QPID 2>/dev/null || true; exit 1 ;;
	boot)
		: > "$LOG"
		"${common[@]}" -display none -serial "file:$LOG" &
		QPID=$!
		if wait_for " login: " "$TIMEOUT"; then
			echo "PASS: installed system reached login prompt"; grep -a "login:" "$LOG" | head -n1
			sleep 5; kill $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true; exit 0
		fi
		echo "FAIL: no login prompt"; tail -n 40 "$LOG"; kill $QPID 2>/dev/null || true; exit 1 ;;
	run)
		exec "${common[@]}" -display none -serial mon:stdio ;;
	*) sed -n '2,6p' "$0"; exit 1 ;;
esac
