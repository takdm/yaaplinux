#!/usr/bin/env bash
# test-vm.sh — boot the YaapLinux release ISO in a QEMU/KVM VM for testing.
#
# Prereqs (one-time, needs sudo):
#   sudo apt install -y qemu-system-x86 qemu-utils ovmf
#
# Usage:
#   ./test-vm.sh              # UEFI boot (default; matches bootloader.uefi path)
#   ./test-vm.sh --bios       # legacy BIOS boot
#   ./test-vm.sh --iso PATH   # different ISO (default: release ISO in scratch)
#
# Creates a sparse 30G qcow2 disk at ~/.cache/yaaplinux-vm/disk.qcow2.
# Delete that file to reset the test machine.
set -euo pipefail

ISO="${ISO:-$HOME/.hermes/cache/scratch/yaaplinux-2026.11.01-x86_64.iso}"
DISK_DIR="$HOME/.cache/yaaplinux-vm"
DISK="$DISK_DIR/disk.qcow2"
FIRMWARE=uefi

while [ $# -gt 0 ]; do
    case "$1" in
        --bios) FIRMWARE=bios; shift ;;
        --iso)  ISO="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

for cmd in qemu-system-x86_64 qemu-img; do
    command -v "$cmd" >/dev/null || { echo "missing $cmd — run: sudo apt install -y qemu-system-x86 qemu-utils ovmf" >&2; exit 1; }
done
[ -f "$ISO" ] || { echo "ISO not found: $ISO" >&2; exit 1; }

mkdir -p "$DISK_DIR"
[ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 30G

ACCEL=kvm
[ -w /dev/kvm ] || { ACCEL=tcg; echo "note: /dev/kvm not writable, using slow TCG emulation"; }

# RAM is limited on this host (~8G); 2G is enough to boot the ISO and run the
# installer, but the Hyprland desktop itself will be tight.
QEMU_ARGS=(
    -machine q35 -accel "$ACCEL"
    -m 2048 -smp 2
    -drive file="$DISK",if=virtio,format=qcow2
    -drive file="$ISO",media=cdrom,readonly=on
    -boot order=d
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    -display gtk
)

if [ "$FIRMWARE" = uefi ]; then
    OVMF_CODE="$(find /usr/share -name 'OVMF_CODE*.fd' 2>/dev/null | grep -v secboot | head -1)"
    [ -n "$OVMF_CODE" ] || { echo "OVMF not found — run: sudo apt install -y ovmf (or use --bios)" >&2; exit 1; }
    QEMU_ARGS+=(-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE")
    echo "booting UEFI (OVMF): $ISO"
else
    echo "booting BIOS: $ISO"
fi

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
