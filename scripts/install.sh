#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -qx "UW VPN"; then
  echo "Quit UW VPN before installing." >&2
  exit 1
fi
./scripts/build.sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/UW VPN.app" # Replace, never merge, the old bundle.
/usr/bin/ditto "build/UW VPN.app" "$HOME/Applications/UW VPN.app"
printf 'Installed: %s/Applications/UW VPN.app\n' "$HOME"
