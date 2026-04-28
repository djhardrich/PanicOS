#!/usr/bin/env bash
# Shared helpers for sync-rocknix.sh and sync-knulli.sh.
set -euo pipefail

sha256_of() {
    [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo ""
}

git_sha256_of() {
    local repo="$1" sha="$2" path="$3"
    git -C "$repo" show "$sha:$path" 2>/dev/null | sha256sum | awk '{print $1}'
}

# Copy submodule:sha:path -> dest, append (dest, src, src_sha, dest_sha) to TSV.
import_file() {
    local repo="$1" sha="$2" src_path="$3" dest="$4" tsv="$5"
    mkdir -p "$(dirname "$dest")"
    git -C "$repo" show "$sha:$src_path" > "$dest"
    local src_sha; src_sha=$(git_sha256_of "$repo" "$sha" "$src_path")
    local dest_sha; dest_sha=$(sha256_of "$dest")
    printf '%s\t%s\t%s\t%s\n' "$dest" "$src_path" "$src_sha" "$dest_sha" >> "$tsv"
}

# Render a manifest section from TSV.
render_manifest_section() {
    local tsv="$1" name="$2" repo_path="$3" sha="$4" root="$5"
    echo "  - name: $name"
    echo "    submodule: $repo_path"
    echo "    sha: $sha"
    echo "    files:"
    while IFS=$'\t' read -r dest src src_sha dest_sha; do
        echo "      - dest: ${dest#$root/}"
        echo "        src: $src"
        echo "        src_sha256: $src_sha"
        echo "        dest_sha256: $dest_sha"
    done < "$tsv"
}

# Drift check: walk a manifest's recorded dest+dest_sha, compare to current
# on-disk SHA. Returns 0 if all match, prints DRIFT lines and returns 1 otherwise.
check_drift() {
    local manifest="$1" root="$2" name_filter="${3:-}"
    [ -f "$manifest" ] || return 0
    local in_section=0 d="" expected=""
    local drifted=0
    while IFS= read -r line; do
        case "$line" in
            "  - name: "*)
                if [ -z "$name_filter" ] || [ "${line#*name: }" = "$name_filter" ]; then
                    in_section=1
                else
                    in_section=0
                fi
                ;;
            "      - dest: "*) [ "$in_section" = 1 ] && d="${line#*dest: }" ;;
            "        dest_sha256: "*)
                [ "$in_section" = 1 ] || continue
                expected="${line#*dest_sha256: }"
                if [ -f "$root/$d" ]; then
                    actual=$(sha256_of "$root/$d")
                    if [ "$actual" != "$expected" ]; then
                        echo "DRIFT: $d (locally modified)" >&2
                        drifted=$((drifted+1))
                    fi
                fi
                ;;
        esac
    done < "$manifest"
    return $((drifted == 0 ? 0 : 1))
}
