#!/usr/bin/env bash
# Reads a command key from .mcu-profile.json and executes it with bash.
# Usage: run-profile-task.sh <key>   e.g.  run-profile-task.sh build
set -euo pipefail

PROFILE_FILE="${PROFILE_FILE:-.mcu-profile.json}"
KEY="$1"

if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: $PROFILE_FILE not found in $(pwd)." >&2
    echo "Run /scaffold-mcu-project <arm|wch|telink> from Claude to set up the workspace." >&2
    exit 1
fi

CMD="$(jq -re ".$KEY" "$PROFILE_FILE" 2>/dev/null)" || {
    echo "ERROR: key '$KEY' not found in $PROFILE_FILE" >&2
    exit 1
}

exec bash -c "$CMD"
