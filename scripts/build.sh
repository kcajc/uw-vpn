#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/UW VPN.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
common=(-swift-version 5 -O -warnings-as-errors -target arm64-apple-macosx13.0)

xcrun swiftc "${common[@]}" Sources/Core.swift Sources/IPC.swift Sources/Runner.swift \
  -o "$app/Contents/MacOS/uw-vpn-runner"
xcrun swiftc "${common[@]}" Sources/Core.swift Sources/IPC.swift Sources/Keychain.swift \
  Sources/Capture.swift Sources/App.swift -framework AppKit -framework Security \
  -o "$app/Contents/MacOS/UW VPN"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>UW VPN</string>
  <key>CFBundleDisplayName</key><string>UW VPN</string>
  <key>CFBundleExecutable</key><string>UW VPN</string>
  <key>CFBundleIdentifier</key><string>net.kcajc.uw-vpn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.5</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp config.example.json "$app/Contents/Resources/"
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 13.0 --target-device mac \
  --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-info.plist" \
  --output-format human-readable-text
/usr/bin/codesign --force --sign - --identifier net.kcajc.uw-vpn.runner "$app/Contents/MacOS/uw-vpn-runner"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
