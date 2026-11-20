#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -qx "UW VPN"; then
  echo "Quit UW VPN before installing." >&2
  exit 1
fi
./scripts/build.sh
dest="$HOME/Applications/UW VPN.app"
staged="$HOME/Applications/.UW VPN.app.installing" # Same volume, so the final mv is a rename.
mkdir -p "$HOME/Applications"
rm -rf "$staged"
trap 'rm -rf "$staged"' EXIT # Gone after a successful mv; removes a partial copy otherwise.
/usr/bin/ditto "build/UW VPN.app" "$staged"
/usr/bin/codesign --verify --deep --strict "$staged"
# Only now replace (never merge into) the working app; an interrupted copy leaves it untouched.
rm -rf "$dest"
mv "$staged" "$dest"
printf 'Installed: %s\n' "$dest"
