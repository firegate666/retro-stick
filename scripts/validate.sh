#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACHINES_DIR="$REPO_ROOT/machines"

errors=0
warnings=0

fail() { echo "  ERROR: $*" >&2; errors=$((errors + 1)); }
warn() { echo "  WARN:  $*"; warnings=$((warnings + 1)); }
ok()   { echo "  ok     $*"; }

# ── Machine configs ───────────────────────────────────────────────────────────

echo "=== Machine configs ==="
for dir in "$MACHINES_DIR"/*/; do
    machine=$(basename "$dir")
    [[ "$machine" == "_template" ]] && continue

    echo "[$machine]"

    for f in core.cfg machine.cfg whitelist.txt; do
        if [[ -f "$dir$f" ]]; then
            ok "$f"
        else
            fail "$machine: missing $f"
        fi
    done

    if [[ -f "${dir}core.cfg" ]]; then
        core_name=$(grep '^CORE_NAME=' "${dir}core.cfg" | cut -d= -f2)
        core_url=$(grep  '^CORE_URL='  "${dir}core.cfg" | cut -d= -f2)
        if [[ -n "$core_name" ]]; then
            ok "CORE_NAME=$core_name"
        else
            fail "$machine: CORE_NAME is empty in core.cfg"
        fi
        if [[ -n "$core_url" ]]; then
            ok "CORE_URL set"
        else
            fail "$machine: CORE_URL is empty in core.cfg"
        fi
    fi
done

# ── Host tools ────────────────────────────────────────────────────────────────

echo ""
echo "=== Host tools ==="

OS=$(uname -s)

check_tool() {
    local cmd="$1" mac_hint="$2" linux_hint="$3"
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd ($(command -v "$cmd"))"
    else
        if [[ "$OS" == "Darwin" ]]; then
            warn "$cmd not found — brew install $mac_hint"
        else
            warn "$cmd not found — apt install $linux_hint"
        fi
    fi
}

check_tool curl       curl          curl
check_tool unzip      unzip         unzip
# sevenzip (Homebrew) installs 7zz; p7zip (Linux) installs 7z — accept either
if command -v 7zz &>/dev/null || command -v 7z &>/dev/null; then
    ok "7z / 7zz ($(command -v 7zz 2>/dev/null || command -v 7z))"
else
    if [[ "$OS" == "Darwin" ]]; then
        warn "7z not found — brew install sevenzip"
    else
        warn "7z not found — apt install p7zip-full"
    fi
fi
check_tool mksquashfs squashfs      squashfs-tools
check_tool dd         "(built-in)"  "(built-in)"
check_tool mtools     mtools        mtools

# grub-mkimage: name varies by platform
# Linux: grub-mkimage or grub2-mkimage
# macOS (x86_64-elf-grub): x86_64-elf-grub-mkimage
if command -v grub-mkimage &>/dev/null \
   || command -v grub2-mkimage &>/dev/null \
   || command -v x86_64-elf-grub-mkimage &>/dev/null; then
    ok "grub-mkimage"
else
    if [[ "$OS" == "Darwin" ]]; then
        warn "grub-mkimage not found — brew install x86_64-elf-grub"
    else
        warn "grub-mkimage not found — apt install grub-pc-bin grub-efi-amd64-bin"
    fi
fi

# syslinux only relevant on Linux
if [[ "$OS" != "Darwin" ]]; then
    check_tool syslinux syslinux syslinux
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [[ $errors -gt 0 ]]; then
    echo "FAILED: $errors error(s), $warnings warning(s)." >&2
    exit 1
else
    echo "OK: all checks passed ($warnings warning(s))."
fi
