#!/usr/bin/env bash
# sync-shared-assets.sh — push this repo's canonical shared assets into the
# leaf repos that cannot inherit them through a Docker layer.
#
# docker-dev-embedded-telink branches off docker-dev-template rather than this
# image (the tc32 toolchain needs multilib, which we keep out of the shared
# base). It therefore carries verbatim copies of three asset sets that live
# here. Without a sync step those copies drift silently.
#
# This repo is the single source of truth for:
#     udev-rules/            probe udev rules
#     run-profile-task.sh    the `mcu` task runner
#     vscode-templates/      tasks.json + launch.json
#     profile.schema.json    profile key reference
#     cmake/                 embedded-common.cmake, host-test.cmake
#
# Usage:
#   ./scripts/sync-shared-assets.sh --check                  drift report, exit 1 if any
#   ./scripts/sync-shared-assets.sh                          copy into sibling repos
#   ./scripts/sync-shared-assets.sh /path/to/docker-dev-embedded-telink

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS=(udev-rules run-profile-task.sh vscode-templates profile.schema.json cmake)

CHECK=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
    shift
fi

if [ $# -gt 0 ]; then
    TARGETS=("$@")
else
    # Default: sibling checkouts that need the copies. One entry today; this is
    # the fan-out list and grows as downstream images are added.
    TARGETS=()
    # shellcheck disable=SC2043
    for name in docker-dev-embedded-telink; do
        candidate="$(dirname "$REPO_ROOT")/$name"
        [ -d "$candidate" ] && TARGETS+=("$candidate")
    done
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "No target repos found. Pass a path explicitly." >&2
    exit 1
fi

drift=0

for target in "${TARGETS[@]}"; do
    echo "=== $target ==="
    for asset in "${ASSETS[@]}"; do
        src="$REPO_ROOT/$asset"
        dst="$target/$asset"

        [ -e "$src" ] || { echo "  SKIP  $asset (not in this repo)"; continue; }

        if [ "$CHECK" = "1" ]; then
            if [ ! -e "$dst" ]; then
                echo "  MISSING  $asset"
                drift=1
            elif diff -qr "$src" "$dst" >/dev/null 2>&1; then
                echo "  ok       $asset"
            else
                echo "  DRIFTED  $asset"
                diff -ru "$dst" "$src" | head -30 | sed 's/^/           /'
                drift=1
            fi
        else
            if [ -d "$src" ]; then
                if command -v rsync >/dev/null 2>&1; then
                    mkdir -p "$dst"
                    rsync -a --delete "$src/" "$dst/"
                else
                    # rsync is not everywhere (notably Git Bash on Windows).
                    rm -rf "$dst"
                    mkdir -p "$dst"
                    cp -a "$src/." "$dst/"
                fi
            else
                cp -p "$src" "$dst"
            fi
            echo "  synced   $asset"
        fi
    done
done

if [ "$CHECK" = "1" ]; then
    if [ "$drift" = "1" ]; then
        echo ""
        echo "Shared assets have drifted. Run without --check to resync, then commit"
        echo "the result in the target repo." >&2
        exit 1
    fi
    echo ""
    echo "All shared assets in sync."
fi
