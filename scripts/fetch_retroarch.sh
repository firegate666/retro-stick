#!/usr/bin/env bash
set -euo pipefail

# Downloads the RetroArch AppImage from the libretro nightly buildbot.
# The buildbot ships a .7z archive containing the AppImage — requires 7z (p7zip).
#
# Archive layout: RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage
# Extracted to:   cache/retroarch/RetroArch.AppImage
#
# Override RETROARCH_URL to pin a specific nightly date or stable release.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$REPO_ROOT/cache/retroarch"
DEST_BINARY="$CACHE_DIR/RetroArch.AppImage"

: "${RETROARCH_URL:=https://buildbot.libretro.com/nightly/linux/x86_64/RetroArch.7z}"

mkdir -p "$CACHE_DIR"

if [[ -f "$DEST_BINARY" && -s "$DEST_BINARY" ]]; then
    echo "RetroArch: already cached, skipping."
    exit 0
fi

# sevenzip (Homebrew) installs 7zz; p7zip (Linux) installs 7z
if command -v 7zz &>/dev/null; then
    SZ=7zz
elif command -v 7z &>/dev/null; then
    SZ=7z
else
    echo "ERROR: 7z / 7zz not found." >&2
    echo "  macOS: brew install sevenzip" >&2
    echo "  Linux: apt install p7zip-full" >&2
    exit 1
fi

archive="$CACHE_DIR/RetroArch.7z"

echo "RetroArch: downloading from $RETROARCH_URL ..."
curl -L --progress-bar --fail -o "$archive" "$RETROARCH_URL"

echo "RetroArch: extracting AppImage ..."
# -e: extract without paths so the file lands flat in $CACHE_DIR
$SZ e -o"$CACHE_DIR" "$archive" \
    "RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage" -y

rm -f "$archive"

# Rename from the archive's internal name to the canonical cache name
extracted="$CACHE_DIR/RetroArch-Linux-x86_64.AppImage"
if [[ -f "$extracted" ]]; then
    mv "$extracted" "$DEST_BINARY"
    chmod +x "$DEST_BINARY"
    echo "RetroArch: saved to $DEST_BINARY"
else
    echo "ERROR: AppImage not found in archive after extraction." >&2
    ls "$CACHE_DIR/" || true
    exit 1
fi
