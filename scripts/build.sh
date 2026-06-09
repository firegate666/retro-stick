#!/usr/bin/env bash
set -euo pipefail

# Builds build/retrostick.img — a complete, flashable USB image.
#
# Requires all Phase 2-4 outputs:
#   cache/retroarch/RetroArch.AppImage  (unused at build time, in rootfs)
#   cache/cores/*.so                    (in rootfs)
#   cache/alpine/vmlinuz-lts
#   cache/alpine/initramfs-lts
#   build/retroroot.sfs
#
# Set IMG_MB to override the default 4096 MiB image size.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$REPO_ROOT/build/retrostick.img"
SFS="$REPO_ROOT/build/retroroot.sfs"

: "${IMG_MB:=4096}"   # 4 GiB default; USB must be at least this large

# ── Pre-flight ────────────────────────────────────────────────────────────────

for f in \
    "$SFS" \
    "$REPO_ROOT/cache/alpine/vmlinuz-lts" \
    "$REPO_ROOT/cache/alpine/initramfs-lts"
do
    [[ -f "$f" ]] || { echo "ERROR: missing required file: $f" >&2; exit 1; }
done

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found." >&2; exit 1
fi

mkdir -p "$REPO_ROOT/build"

# ── 1. Create blank image ─────────────────────────────────────────────────────

echo "Creating ${IMG_MB} MiB image..."
dd if=/dev/zero of="$IMG" bs=1M count=0 seek="$IMG_MB" 2>/dev/null

# ── 2. Partition + format ─────────────────────────────────────────────────────

bash "$REPO_ROOT/scripts/partition_usb.sh" "$IMG"

# ── 3. Write RETROROOT (raw SquashFS) ─────────────────────────────────────────

echo "Writing RETROROOT SquashFS..."
docker run --rm --privileged --platform linux/amd64 \
    -v "$IMG:/disk" \
    -v "$SFS:/retroroot.sfs:ro" \
    alpine:latest sh -euc '
        apk add --no-cache util-linux kpartx >/dev/null 2>&1
        LOOP=$(losetup -f --show /disk)
        kpartx -as "$LOOP"
        LOOPNAME=$(basename "$LOOP")
        dd if=/retroroot.sfs of="/dev/mapper/${LOOPNAME}p3" bs=4M
        kpartx -ds "$LOOP"
        losetup -d "$LOOP"
    '

# ── 4. Install bootloader + boot files ───────────────────────────────────────

bash "$REPO_ROOT/scripts/install_bootloader.sh" "$IMG"

# ── 5. Populate RETROGAMES ────────────────────────────────────────────────────

echo "Populating RETROGAMES..."
docker run --rm --privileged --platform linux/amd64 \
    -v "$IMG:/disk" \
    -v "$REPO_ROOT/machines:/machines:ro" \
    alpine:latest sh -euc '
        apk add --no-cache exfatprogs util-linux kpartx >/dev/null 2>&1

        LOOP=$(losetup -f --show /disk)
        kpartx -as "$LOOP"
        LOOPNAME=$(basename "$LOOP")

        mkdir -p /mnt/games
        mount "/dev/mapper/${LOOPNAME}p4" /mnt/games

        mkdir -p /mnt/games/machines

        # Copy machine.cfg for each machine (init script uses it at boot)
        for cfg in /machines/*/machine.cfg; do
            machine=$(basename "$(dirname "$cfg")")
            [ "$machine" = "_template" ] && continue
            mkdir -p "/mnt/games/machines/$machine"
            cp "$cfg" "/mnt/games/machines/$machine/machine.cfg"
        done

        umount /mnt/games
        kpartx -ds "$LOOP"
        losetup -d "$LOOP"
    '

# ── 6. Apply whitelists (copy disk images) ────────────────────────────────────

total_copied=0
for cfg in "$REPO_ROOT/machines"/*/core.cfg; do
    machine=$(basename "$(dirname "$cfg")")
    [[ "$machine" == "_template" ]] && continue

    src_disks="$REPO_ROOT/machines/$machine/disks"
    dest_disks="$REPO_ROOT/build/staging/$machine"

    mkdir -p "$dest_disks"
    bash "$REPO_ROOT/scripts/apply_whitelist.sh" \
        "$machine" "$src_disks" "$dest_disks" 2>/dev/null || true
done

# Mount RETROGAMES and copy staged disk images
if find "$REPO_ROOT/build/staging" -name '*' -not -type d | grep -q .; then
    echo "Copying disk images to RETROGAMES..."
    docker run --rm --privileged --platform linux/amd64 \
        -v "$IMG:/disk" \
        -v "$REPO_ROOT/build/staging:/staging:ro" \
        alpine:latest sh -euc '
            apk add --no-cache exfatprogs util-linux kpartx >/dev/null 2>&1
            losetup -j /disk 2>/dev/null | cut -d: -f1 | xargs -r -I% sh -c 'losetup -d "%" 2>/dev/null || true'
            LOOP=$(losetup -f --show /disk)
            kpartx -as "$LOOP"
            LOOPNAME=$(basename "$LOOP")
            mkdir -p /mnt/games
            mount "/dev/mapper/${LOOPNAME}p4" /mnt/games
            for machine_dir in /staging/*/; do
                machine=$(basename "$machine_dir")
                [ -z "$(ls "$machine_dir" 2>/dev/null)" ] && continue
                mkdir -p "/mnt/games/machines/$machine/disks"
                cp "$machine_dir"/* "/mnt/games/machines/$machine/disks/"
            done
            umount /mnt/games
            kpartx -ds "$LOOP"
            losetup -d "$LOOP"
        '
fi

rm -rf "$REPO_ROOT/build/staging"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Build complete ==="
echo "  Image: $IMG"
echo "  Size:  $(du -sh "$IMG" | cut -f1)"
echo ""
echo "Machines included:"
for cfg in "$REPO_ROOT/machines"/*/core.cfg; do
    machine=$(basename "$(dirname "$cfg")")
    [[ "$machine" == "_template" ]] && continue
    core=$(grep '^CORE_NAME=' "$cfg" | cut -d= -f2)
    printf "  %-12s %s\n" "$machine" "$core"
done
echo ""
echo "Flash with:  make flash DEVICE=/dev/sdX"
