#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORES_DIR="$REPO_ROOT/cache/cores"

mkdir -p "$CORES_DIR"

ok=0
skipped=0
failed=0

for cfg in "$REPO_ROOT/machines"/*/core.cfg; do
    machine=$(basename "$(dirname "$cfg")")
    [[ "$machine" == "_template" ]] && continue

    core_name=$(grep '^CORE_NAME=' "$cfg" | cut -d= -f2)
    core_url=$(grep  '^CORE_URL='  "$cfg" | cut -d= -f2)

    if [[ -z "$core_name" || -z "$core_url" ]]; then
        echo "[$machine] CORE_NAME or CORE_URL empty — skipping."
        continue
    fi

    so_file="$CORES_DIR/${core_name}.so"

    if [[ -f "$so_file" ]]; then
        echo "[$machine] $core_name: already cached, skipping."
        skipped=$((skipped + 1))
        continue
    fi

    zip_file="$CORES_DIR/${core_name}.so.zip"

    echo "[$machine] Downloading $core_name ..."
    if curl -L --progress-bar --fail -o "$zip_file" "$core_url"; then
        echo "[$machine] Extracting ..."
        # -j: junk paths (flat extract); -o: overwrite without prompting
        unzip -j -o "$zip_file" -d "$CORES_DIR"
        rm -f "$zip_file"

        if [[ -f "$so_file" ]]; then
            echo "[$machine] $core_name: done."
            ok=$((ok + 1))
        else
            echo "[$machine] WARNING: $so_file not found after extract — zip may use a different filename." >&2
            ls "$CORES_DIR/"*.so 2>/dev/null | tail -5 || true
            failed=$((failed + 1))
        fi
    else
        echo "[$machine] ERROR: download failed for $core_url" >&2
        rm -f "$zip_file"
        failed=$((failed + 1))
    fi
done

echo ""
echo "Cores: $ok downloaded, $skipped already cached, $failed failed."
[[ $failed -eq 0 ]] || exit 1
