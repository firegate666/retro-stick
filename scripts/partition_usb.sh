#!/usr/bin/env bash
set -euo pipefail

# Partitions and formats a disk image (or block device) with the RetroStick
# 4-partition GPT layout.  All disk work runs inside a privileged Docker
# container so the script is portable across macOS and Linux.
#
# Usage: partition_usb.sh <image-file-or-block-device>
#
# Resulting layout (1 MiB aligned):
#   Partition 1  BIOSBOOT       1 MiB   raw    (GRUB BIOS embedding gap)
#   Partition 2  RETROBOOT    512 MiB   FAT32  (EFI System Partition + kernel)
#   Partition 3  RETROROOT   3072 MiB   ext4   (Alpine rootfs, label RETROROOT)
#   Partition 4  RETROGAMES  remainder  exFAT  (disk images, saves)

TARGET="$(cd "$(dirname "${1:?Usage: $0 <image-or-device>}")" && pwd)/$(basename "$1")"

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found." >&2; exit 1
fi

echo "Partitioning: $TARGET"

docker run --rm --privileged --platform linux/amd64 \
    -v "$TARGET:/disk" \
    alpine:latest sh -euc '
        apk add --no-cache parted dosfstools exfatprogs e2fsprogs util-linux kpartx >/dev/null 2>&1

        # Partition table
        parted -s /disk mklabel gpt
        parted -s /disk mkpart BIOSBOOT         1MiB    2MiB    # GRUB BIOS embedding
        parted -s /disk set 1 bios_grub on
        parted -s /disk mkpart RETROBOOT fat32  2MiB  514MiB    # EFI + kernel
        parted -s /disk set 2 esp on
        parted -s /disk set 2 legacy_boot on
        parted -s /disk mkpart RETROROOT        514MiB 3586MiB  # ext4 rootfs (~3 GiB)
        parted -s /disk mkpart RETROGAMES       3586MiB 100%    # exFAT games
        parted -s /disk print

        # Attach loop device and create partition mappings via kpartx
        # (losetup -P partition scanning is unreliable inside Docker on macOS)
        LOOP=$(losetup -f --show /disk)
        kpartx -as "$LOOP"
        LOOPNAME=$(basename "$LOOP")

        mkfs.fat  -F32 -n RETROBOOT  "/dev/mapper/${LOOPNAME}p2"
        mkfs.ext4 -L   RETROROOT     "/dev/mapper/${LOOPNAME}p3"
        mkfs.exfat -n  RETROGAMES    "/dev/mapper/${LOOPNAME}p4"

        kpartx -ds "$LOOP"
        losetup -d "$LOOP"
        echo "Partitioning complete."
    '
