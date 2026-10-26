#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
mkdir -p "$HOME/Applications"
/usr/bin/ditto "build/UW VPN.app" "$HOME/Applications/UW VPN.app"
printf 'Installed: %s/Applications/UW VPN.app\n' "$HOME"
