#!/usr/bin/env bash
set -euo pipefail

# Builds the Alpine x86-64 rootfs that lives on the RETROROOT SquashFS partition.
#
# Requires Docker (linux/amd64 emulation — works on Apple Silicon via Rosetta).
# Uses alpine:3.20; override with ALPINE_IMAGE env var to use a different version.
#
# Outputs:
#   build/rootfs/               — full filesystem tree (written to RETROROOT ext4)
#   cache/alpine/vmlinuz-lts    — kernel for RETROBOOT
#   cache/alpine/initramfs-lts  — initramfs for RETROBOOT

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="$REPO_ROOT/build/rootfs"
CONTAINER="retrostick-rootfs-$$"

: "${ALPINE_IMAGE:=alpine:3.20}"

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
    # Add community repo pinned to the same version as the base image
    ALPINE_VER=\$(cut -d. -f1,2 /etc/alpine-release)
    echo "https://dl-cdn.alpinelinux.org/alpine/v\${ALPINE_VER}/community" \
        >> /etc/apk/repositories
    apk update -q
    # GTK post-install triggers (pulled in by retroarch) fail in a headless
    # container environment — ignore the exit code and verify manually below.
    apk add --no-cache \
        alpine-base \
        openrc \
        linux-lts \
        retroarch \
        mesa-dri-gallium \
        mesa-gbm \
        mesa-egl \
        libdrm \
        alsa-lib \
        alsa-utils \
        gcompat \
        exfatprogs \
        eudev \
        udev-init-scripts \
        util-linux \
        kbd || true
    command -v retroarch  || { echo 'ERROR: retroarch failed to install'; exit 1; }
    test -d /lib/modules  || { echo 'ERROR: linux-lts failed to install'; exit 1; }
"

# ── Firmware: keep everything ────────────────────────────────────────────────
#
# This is a portable USB stick intended to boot on arbitrary hardware. We
# can't know in advance which GPU/WiFi/peripheral firmware will be needed,
# so we ship the full linux-firmware set (~900 MB). The 3 GiB RETROROOT
# partition has room. Trimming firmware previously caused boot failures
# on machines whose drivers needed firmware blobs we removed.

echo "Configuring initramfs..."
docker exec "$CONTAINER" sh -c "
    # Minimal feature set: USB boot + ext4 root mount + NVMe/SATA/IDE
    cat > /etc/mkinitfs/mkinitfs.conf << 'CONF'
features=\"ata base ext4 ide scsi usb virtio nvme\"
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
