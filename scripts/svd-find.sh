#!/usr/bin/env bash
# svd-find — locate a CMSIS-SVD file for a chip in the image's SVD store.
#
# Usage:
#   svd-find                 list the stores and how many files each holds
#   svd-find stm32f407       fuzzy search, best matches first
#   svd-find --set stm32f407 write the best match into .mcu-profile.json SVD_FILE
#   svd-find --pack stm32wba use pyocd's CMSIS-Pack index for parts the stores
#                            do not cover (needs network on first use)
#
# Stores searched (in order, most specific first):
#   $SVD_STORE/stm32          modm-io/cmsis-svd-stm32   (arm leaf only)
#   $SVD_STORE/cmsis-svd-data cmsis-svd/cmsis-svd-data  (multi-vendor)
#   /workspace                anything the project ships itself

set -euo pipefail

SVD_STORE="${SVD_STORE:-/opt/svd}"
PROFILE_FILE="${PROFILE_FILE:-.mcu-profile.json}"

stores() {
    [ -d "$SVD_STORE/stm32" ]           && echo "$SVD_STORE/stm32"
    [ -d "$SVD_STORE/cmsis-svd-data" ]  && echo "$SVD_STORE/cmsis-svd-data"
    [ -d /workspace ]                   && echo /workspace
    true
}

all_svds() {
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        find "$dir" -maxdepth 4 -type f \( -iname '*.svd' \) 2>/dev/null
    done < <(stores)
}

usage_summary() {
    echo "SVD stores:"
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        printf '  %-32s %s file(s)\n' "$dir" \
            "$(find "$dir" -maxdepth 4 -type f -iname '*.svd' 2>/dev/null | wc -l)"
    done < <(stores)
    echo
    echo "Usage: svd-find <chip>   e.g. svd-find stm32wba55"
}

# Score matches: exact basename beats prefix beats substring, longer match wins.
search() {
    local q="${1,,}"
    local qtrim="${q//[^a-z0-9]/}"
    all_svds | while IFS= read -r f; do
        local base="${f##*/}"
        local name="${base%.*}"
        local n="${name,,}"
        local ntrim="${n//[^a-z0-9]/}"
        local score=0
        if   [ "$ntrim" = "$qtrim" ];          then score=100
        elif [[ "$qtrim" == "$ntrim"* ]];      then score=$(( 80 + ${#ntrim} ))
        elif [[ "$ntrim" == "$qtrim"* ]];      then score=$(( 60 + ${#qtrim} ))
        elif [[ "$ntrim" == *"$qtrim"* ]];     then score=40
        else continue
        fi
        printf '%03d\t%s\n' "$score" "$f"
    done | sort -rn | cut -f2-
}

case "${1:-}" in
    "" )
        usage_summary
        ;;
    --pack )
        shift
        [ $# -ge 1 ] || { echo "ERROR: --pack needs a chip pattern" >&2; exit 1; }
        echo "Searching CMSIS-Pack index via pyocd (first run downloads the index)..."
        pyocd pack find "$1"
        echo
        echo "Install device support and its SVD with:  pyocd pack install <device>"
        echo "Installed packs live under \$PYOCD_HOME (${PYOCD_HOME:-~/.local/share/cmsis-pack-manager})."
        ;;
    --set )
        shift
        [ $# -ge 1 ] || { echo "ERROR: --set needs a chip pattern" >&2; exit 1; }
        best="$(search "$1" | head -1)"
        [ -n "$best" ] || { echo "ERROR: no SVD matched '$1'. Try: svd-find --pack $1" >&2; exit 1; }
        [ -f "$PROFILE_FILE" ] || { echo "ERROR: $PROFILE_FILE not found" >&2; exit 1; }
        tmp="$(mktemp)"
        jq --arg p "$best" '.SVD_FILE = $p' "$PROFILE_FILE" > "$tmp" && mv "$tmp" "$PROFILE_FILE"
        echo "SVD_FILE = $best"
        echo "(run 'mcu --export' to refresh .vscode/.profile.env)"
        ;;
    * )
        results="$(search "$1")"
        if [ -z "$results" ]; then
            echo "No SVD matched '$1' in $SVD_STORE." >&2
            echo "Recent silicon is often missing from the open mirrors — try:" >&2
            echo "    svd-find --pack $1" >&2
            exit 1
        fi
        echo "$results" | head -20
        ;;
esac
