#!/usr/bin/env bash
set -euo pipefail

# Writes build/retrostick.img to a USB device.
# Prompts for confirmation before writing.
#
# Usage: flash.sh <device>
# Example (Linux):  flash.sh /dev/sdb
# Example (macOS):  flash.sh /dev/disk2

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$REPO_ROOT/build/retrostick.img"
DEVICE="${1:?Usage: $0 <device>}"

[[ -f "$IMG" ]] || { echo "ERROR: $IMG not found — run 'make build' first." >&2; exit 1; }

OS=$(uname -s)

# ── WSL2 reminder ─────────────────────────────────────────────────────────────

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo ""
    echo "WSL2 detected. The USB device must be attached via usbipd-win first."
    echo ""
    echo "  In Windows PowerShell (admin):"
    echo "    usbipd list"
    echo "    usbipd attach --wsl --busid <BUSID>"
    echo ""
fi

# ── Confirm ───────────────────────────────────────────────────────────────────

IMG_SIZE=$(du -sh "$IMG" | cut -f1)

echo "Image:  $IMG  ($IMG_SIZE)"
echo "Target: $DEVICE"
echo ""
printf "Write to %s? THIS WILL ERASE THE DEVICE. [y/N] " "$DEVICE"
read -r answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Unmount any mounted volumes from the device (macOS) ──────────────────────

if [[ "$OS" == "Darwin" ]]; then
    diskutil unmountDisk "$DEVICE" 2>/dev/null || true
fi

# ── Flash ─────────────────────────────────────────────────────────────────────

echo "Flashing..."

if [[ "$OS" == "Darwin" ]]; then
    # macOS: use /dev/rdiskN (raw) for faster writes; bs lowercase
    raw_device="${DEVICE/\/dev\/disk//dev/rdisk}"
    sudo dd if="$IMG" of="$raw_device" bs=4m conv=sync status=progress
else
    sudo dd if="$IMG" of="$DEVICE" bs=4M conv=fsync status=progress
fi

sync
echo ""
echo "Done. Safe to remove USB."
