#!/usr/bin/env bash
set -euo pipefail

# Builds the Alpine x86-64 rootfs that lives on the RETROROOT SquashFS partition.
#
# Requires Docker (linux/amd64 emulation — works on Apple Silicon via Rosetta).
# Uses alpine:latest; pin ALPINE_IMAGE in the environment to lock a version.
#
# Outputs:
#   build/rootfs/          — full filesystem tree
#   cache/alpine/vmlinuz-lts    — kernel for RETROBOOT
#   cache/alpine/initramfs-lts  — initramfs for RETROBOOT

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="$REPO_ROOT/build/rootfs"
CONTAINER="retrostick-rootfs-$$"

: "${ALPINE_IMAGE:=alpine:latest}"

# ── Pre-flight ────────────────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found." >&2
    echo "  Install Docker Desktop: https://docs.docker.com/get-docker/" >&2
    exit 1
fi

for f in \
    "$REPO_ROOT/cache/cores/"*.so \
    "$REPO_ROOT/config/retroarch_base.cfg" \
    "$REPO_ROOT/scripts/retroarch-launch.start"
do
    [[ -f "$f" ]] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

# ── Cleanup on exit ───────────────────────────────────────────────────────────

cleanup() {
    if docker inspect "$CONTAINER" &>/dev/null 2>&1; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ── Bootstrap ─────────────────────────────────────────────────────────────────

echo "=== Building Alpine x86-64 rootfs (image: $ALPINE_IMAGE) ==="
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

docker run -d --platform linux/amd64 --name "$CONTAINER" \
    "$ALPINE_IMAGE" sleep 3600

# ── Install packages ──────────────────────────────────────────────────────────

echo "Installing packages..."
docker exec "$CONTAINER" sh -c "
    # Add community repo (retroarch lives here)
    echo 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/community' \
        >> /etc/apk/repositories
    apk update -q
    apk add --no-cache \
        alpine-base \
        openrc \
        linux-lts \
        retroarch \
        exfatprogs \
        eudev \
        udev-init-scripts \
        util-linux \
        kbd
"

# ── Trim firmware: keep GPU-only, regenerate minimal initramfs ────────────────
#
# linux-lts pulls in all ~200 linux-firmware packages (~900 MB).
# We only need GPU firmware for Intel (i915) and AMD (amdgpu/radeon) to get
# KMS/DRM output on real hardware. Everything else (WiFi, BT, DSP, etc.) is
# irrelevant for a headless gaming stick.
#
# This also makes mkinitfs produce a small initramfs (~10-30 MB instead of
# 170 MB) because the firmware it can reference is now minimal.
#
# NOTE: RETROROOT ends up ~1.5-2 GB uncompressed; SquashFS xz brings it to
# roughly 700-900 MB — within a 1.5 GB partition with margin. Partition sizing
# is handled in Phase 5 (partition_usb.sh).

echo "Trimming firmware to GPU-only..."
docker exec "$CONTAINER" sh -c "
    cd /lib/firmware

    # Stash GPU firmware we want to keep
    for dir in i915 amdgpu radeon amd nvidia; do
        [ -d \"\$dir\" ] && mv \"\$dir\" \"/tmp/fw_\$dir\"
    done

    # Remove everything else
    rm -rf /lib/firmware/*

    # Restore GPU firmware
    for dir in i915 amdgpu radeon amd nvidia; do
        [ -d \"/tmp/fw_\$dir\" ] && mv \"/tmp/fw_\$dir\" \"\$dir\"
    done
"

echo "Configuring initramfs..."
docker exec "$CONTAINER" sh -c "
    # Minimal feature set: USB boot + SquashFS root mount + NVMe/SATA/IDE
    cat > /etc/mkinitfs/mkinitfs.conf << 'CONF'
features=\"ata base ide scsi usb virtio squashfs nvme\"
CONF
    mkinitfs \$(ls /lib/modules/ | head -1)
"

echo "Cleaning apk cache..."
docker exec "$CONTAINER" sh -c "rm -rf /var/cache/apk/* /tmp/*"

# ── Enable OpenRC services ────────────────────────────────────────────────────

echo "Enabling services..."
docker exec "$CONTAINER" sh -c "
    rc-update add udev sysinit
    rc-update add udev-trigger sysinit
    rc-update add local default
"

# ── Directories ───────────────────────────────────────────────────────────────

docker exec "$CONTAINER" sh -c "
    mkdir -p /opt/retroarch/cores
    mkdir -p /media/RETROGAMES
"

# ── Copy assets into container ────────────────────────────────────────────────

echo "Copying libretro cores..."
for so in "$REPO_ROOT/cache/cores/"*.so; do
    docker cp "$so" "$CONTAINER:/opt/retroarch/cores/"
done

echo "Copying RetroArch base config..."
docker cp "$REPO_ROOT/config/retroarch_base.cfg" \
    "$CONTAINER:/opt/retroarch/retroarch.cfg"

echo "Installing launcher init script..."
docker cp "$REPO_ROOT/scripts/retroarch-launch.start" \
    "$CONTAINER:/etc/local.d/retroarch-launch.start"
docker exec "$CONTAINER" chmod +x /etc/local.d/retroarch-launch.start

# ── Export filesystem ─────────────────────────────────────────────────────────

echo "Exporting rootfs (may take a minute)..."
docker export "$CONTAINER" | tar -C "$ROOTFS" -xf -

# ── Cache kernel + initramfs for RETROBOOT ────────────────────────────────────

echo "Caching kernel and initramfs..."
mkdir -p "$REPO_ROOT/cache/alpine"
cp "$ROOTFS/boot/vmlinuz-lts"   "$REPO_ROOT/cache/alpine/vmlinuz-lts"
cp "$ROOTFS/boot/initramfs-lts" "$REPO_ROOT/cache/alpine/initramfs-lts"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Rootfs build complete ==="
echo "  Kernel:    cache/alpine/vmlinuz-lts    ($(du -sh "$REPO_ROOT/cache/alpine/vmlinuz-lts" | cut -f1))"
echo "  Initramfs: cache/alpine/initramfs-lts  ($(du -sh "$REPO_ROOT/cache/alpine/initramfs-lts" | cut -f1))"
echo "  Rootfs:    build/rootfs/               ($(du -sh "$ROOTFS" | cut -f1))"
echo ""
echo "Cores in rootfs:"
ls -1 "$ROOTFS/opt/retroarch/cores/"
