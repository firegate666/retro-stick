#!/usr/bin/env bash
set -euo pipefail

# Usage: apply_whitelist.sh <machine> <source-disks-dir> <dest-dir>
#
# Reads machines/<machine>/whitelist.txt and copies only the listed files
# from <source-disks-dir> to <dest-dir>. Warns about whitelisted filenames
# that are absent from the source; does not fail on missing files so a
# partial disk collection still produces a usable build.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 3 ]]; then
    echo "Usage: $(basename "$0") <machine> <source-disks-dir> <dest-dir>" >&2
    exit 1
fi

machine="$1"
src_dir="$2"
dest_dir="$3"
whitelist="$REPO_ROOT/machines/$machine/whitelist.txt"

if [[ ! -f "$whitelist" ]]; then
    echo "ERROR: whitelist not found: $whitelist" >&2
    exit 1
fi

if [[ ! -d "$src_dir" ]]; then
    echo "ERROR: source directory not found: $src_dir" >&2
    exit 1
fi

mkdir -p "$dest_dir"

copied=0
missing=0

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ -f "$src_dir/$line" ]]; then
        cp "$src_dir/$line" "$dest_dir/$line"
        echo "  copied:  $line"
        copied=$((copied + 1))
    else
        echo "  missing: $line (not in source — skipping)" >&2
        missing=$((missing + 1))
    fi
done < "$whitelist"

echo "[$machine] $copied copied, $missing not found in source."
