#!/usr/bin/env bash
set -euo pipefail

# Installs the bootloader onto a disk image (or block device):
#   - GRUB EFI  → RETROBOOT/EFI/BOOT/BOOTX64.EFI  (UEFI path)
#   - GRUB BIOS → embedded in BIOSBOOT partition (legacy BIOS path)
#   - Copies kernel, initramfs, and grub.cfg to RETROBOOT
#
# The GRUB EFI binary uses a search-by-label probe so it works regardless of
# which disk slot the USB occupies.  GRUB BIOS is installed via grub-install
# which embeds core.img in the GPT BIOS Boot partition (P1, bios_grub flag).
#
# Usage: install_bootloader.sh <image-or-device>

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$(cd "$(dirname "${1:?Usage: $0 <image-or-device>}")" && pwd)/$(basename "$1")"

GRUB_CFG="$REPO_ROOT/boot/grub/grub.cfg"
KERNEL="$REPO_ROOT/cache/alpine/vmlinuz-lts"
INITRD="$REPO_ROOT/cache/alpine/initramfs-lts"

for f in "$GRUB_CFG" "$KERNEL" "$INITRD"; do
    [[ -f "$f" ]] || { echo "ERROR: missing required file: $f" >&2; exit 1; }
done

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found." >&2; exit 1
fi

echo "Installing bootloader on: $TARGET"

docker run --rm --privileged --platform linux/amd64 \
    -v "$TARGET:/disk" \
    -v "$GRUB_CFG:/grub.cfg:ro" \
    -v "$KERNEL:/vmlinuz-lts:ro" \
    -v "$INITRD:/initramfs-lts:ro" \
    alpine:latest sh -euc '
        apk add --no-cache grub grub-efi grub-bios util-linux >/dev/null 2>&1

        # Partition layout (MiB-aligned, fixed offsets):
        #   P1 BIOSBOOT   1-2 MiB    (bios_grub, raw)
        #   P2 RETROBOOT  2-514 MiB  (FAT32)
        BOOT_OFFSET=$((2*1024*1024))
        BOOT_SIZE=$((512*1024*1024))

        # Separate loop devices: disk (whole image) + boot partition (by offset)
        DISK_LOOP=$(losetup -f --show /disk)
        BOOT_LOOP=$(losetup -f --show --offset "$BOOT_OFFSET" --sizelimit "$BOOT_SIZE" /disk)

        mkdir -p /mnt/boot
        mount "$BOOT_LOOP" /mnt/boot

        # ── Boot files ────────────────────────────────────────────────────────
        mkdir -p /mnt/boot/boot/grub /mnt/boot/EFI/BOOT
        cp /grub.cfg      /mnt/boot/boot/grub/grub.cfg
        cp /vmlinuz-lts   /mnt/boot/boot/vmlinuz-lts
        cp /initramfs-lts /mnt/boot/boot/initramfs-lts

        # ── GRUB EFI (UEFI path) ──────────────────────────────────────────────
        # Embed a small config that finds RETROBOOT by label, then loads the
        # real grub.cfg from it. Robust regardless of which hd slot the USB is.
        cat > /tmp/grub-early.cfg << '"'"'GCFG'"'"'
search --no-floppy --label --set=root RETROBOOT
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
GCFG

        grub-mkimage \
            --format=x86_64-efi \
            --output=/mnt/boot/EFI/BOOT/BOOTX64.EFI \
            --prefix=/boot/grub \
            --config=/tmp/grub-early.cfg \
            part_gpt fat normal search search_label linux echo configfile

        # ── GRUB BIOS (legacy path) ───────────────────────────────────────────
        # grub-install embeds core.img in the BIOSBOOT partition (P1, bios_grub)
        # and writes boot.img to the MBR.  --boot-directory points to the
        # directory on RETROBOOT where GRUB modules and grub.cfg live.
        grub-install \
            --target=i386-pc \
            --boot-directory=/mnt/boot/boot \
            --no-nvram \
            "$DISK_LOOP"

        umount /mnt/boot
        losetup -d "$BOOT_LOOP"
        losetup -d "$DISK_LOOP"
        echo "Bootloader installed."
    '
