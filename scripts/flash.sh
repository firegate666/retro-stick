#!/usr/bin/env bash
set -euo pipefail

# Writes build/retrostick.img to a USB device.
# With no argument: shows a menu of connected USB/removable drives to pick from.
# With a device argument: uses that device directly.
#
# Usage: flash.sh [device]
# Example (Linux):  flash.sh /dev/sdb
# Example (macOS):  flash.sh /dev/disk2

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$REPO_ROOT/build/retrostick.img"
OS=$(uname -s)

[[ -f "$IMG" ]] || { echo "ERROR: $IMG not found — run 'make build' first." >&2; exit 1; }

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

# ── Device selector ───────────────────────────────────────────────────────────

list_devices_macos() {
    # Parse `diskutil list` for "(external, physical)" disks, then get details.
    local devs=() labels=()
    while IFS= read -r dev; do
        local info size model protocol
        info=$(diskutil info "$dev" 2>/dev/null) || continue
        size=$(echo  "$info" | awk -F': *' '/Disk Size:/          {gsub(/ *\(.*/, "", $2); print $2}')
        model=$(echo "$info" | awk -F': *' '/Device \/ Media Name:/{print $2}')
        protocol=$(echo "$info" | awk -F': *' '/Protocol:/         {print $2}')
        devs+=("$dev")
        labels+=("$(printf "%-12s  %-10s  %s  [%s]" "$dev" "$size" "$model" "$protocol")")
    done < <(diskutil list 2>/dev/null | awk '/\(external, physical\)/{print $1}')
    printf '%s\n' "${devs[@]+"${devs[@]}"}"$'\x00'"${labels[@]+"${labels[@]}"}"
    # Return via global arrays — caller unpacks below
    _DEVS=("${devs[@]+"${devs[@]}"}"); _LABELS=("${labels[@]+"${labels[@]}"}")
}

list_devices_linux() {
    local devs=() labels=()
    # Primary: lsblk transport=usb
    while IFS= read -r line; do
        local name size model
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | cut -d' ' -f4- | sed 's/^ *//')
        [[ -b "/dev/$name" ]] || continue
        devs+=("/dev/$name")
        labels+=("$(printf "%-12s  %-10s  %s" "/dev/$name" "$size" "$model")")
    done < <(lsblk -d -o NAME,SIZE,TRAN,MODEL --noheadings 2>/dev/null | awk '$3=="usb"')

    # Fallback: any removable block device (covers SD cards, etc.)
    if [[ ${#devs[@]} -eq 0 ]]; then
        for sysdev in /sys/block/*/; do
            local name="/dev/$(basename "$sysdev")"
            [[ -b "$name" ]] || continue
            [[ "$(cat "$sysdev/removable" 2>/dev/null)" == "1" ]] || continue
            local size model
            size=$(lsblk -d -o SIZE --noheadings "$name" 2>/dev/null | tr -d ' ')
            model=$(lsblk -d -o MODEL --noheadings "$name" 2>/dev/null | sed 's/^ *//')
            devs+=("$name")
            labels+=("$(printf "%-12s  %-10s  %s" "$name" "$size" "$model")")
        done
    fi
    _DEVS=("${devs[@]+"${devs[@]}"}"); _LABELS=("${labels[@]+"${labels[@]}"}")
}

select_device() {
    _DEVS=(); _LABELS=()
    if [[ "$OS" == "Darwin" ]]; then
        list_devices_macos
    else
        list_devices_linux
    fi

    if [[ ${#_DEVS[@]} -eq 0 ]]; then
        echo "No USB/removable drives detected."
        echo ""
        echo "Specify the device manually:"
        echo "  make flash DEVICE=/dev/sdX          (Linux/WSL2)"
        echo "  make flash DEVICE=/dev/diskN        (macOS)"
        exit 1
    fi

    echo "Connected USB / removable drives:"
    echo ""
    local i
    for i in "${!_DEVS[@]}"; do
        printf "  %d)  %s\n" $((i + 1)) "${_LABELS[$i]}"
    done
    echo ""
    printf "Select drive [1-%d] or Enter to cancel: " "${#_DEVS[@]}"

    local choice
    read -r choice </dev/tty
    echo ""

    if [[ -z "$choice" ]]; then
        echo "Cancelled."
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || \
       [[ "$choice" -lt 1 ]] || \
       [[ "$choice" -gt "${#_DEVS[@]}" ]]; then
        echo "Invalid selection." >&2
        exit 1
    fi

    DEVICE="${_DEVS[$((choice - 1))]}"
}

# Use argument if provided, otherwise show selector
DEVICE="${1:-}"
[[ -n "$DEVICE" ]] || select_device

# ── Confirm ───────────────────────────────────────────────────────────────────

IMG_SIZE=$(du -sh "$IMG" | cut -f1)

echo "Image:  $IMG  ($IMG_SIZE)"
echo "Target: $DEVICE"
echo ""
printf "Write to %s? THIS WILL ERASE THE DEVICE. [y/N] " "$DEVICE"
read -r answer </dev/tty
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Unmount any mounted volumes from the device (macOS) ──────────────────────

if [[ "$OS" == "Darwin" ]]; then
    diskutil unmountDisk "$DEVICE" 2>/dev/null || true
fi

# ── Flash ─────────────────────────────────────────────────────────────────────

echo "Flashing..."

if [[ "$OS" == "Darwin" ]]; then
    raw_device="${DEVICE/\/dev\/disk//dev/rdisk}"
    sudo dd if="$IMG" of="$raw_device" bs=4m conv=sync status=progress
else
    sudo dd if="$IMG" of="$DEVICE" bs=4M conv=fsync status=progress
fi

sync
echo ""
echo "Done. Safe to remove USB."
