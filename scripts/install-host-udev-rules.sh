#!/usr/bin/env bash
# Installs udev rules for all supported debug probes on the HOST machine.
#
# Run this ONCE on the Linux host so probe device nodes get correct group
# ownership and are accessible to the Docker container's bind-mount.
#
# udev does not run inside the container — the rules in /etc/udev/rules.d/
# inside the image have no effect at runtime. The rules here apply to the host.
#
# Usage: sudo ./scripts/install-host-udev-rules.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_SRC="$SCRIPT_DIR/udev-rules"
RULES_DEST="/etc/udev/rules.d"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run with sudo" >&2
    exit 1
fi

echo "Installing udev rules from $RULES_SRC to $RULES_DEST ..."
cp -v "$RULES_SRC"/*.rules "$RULES_DEST/"

echo "Reloading udev rules ..."
udevadm control --reload-rules
udevadm trigger

echo ""
echo "Done. Replug your debug probe for the new rules to take effect."
echo "If the container is already running, restart it after replugging."
