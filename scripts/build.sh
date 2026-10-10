#!/bin/bash
# Builds Hush.app into build/. Overwrites the previous build in place.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Hush"
APP="build/Hush.app"

mkdir -p "$APP/Contents/MacOS"
cp -f "$BIN" "$APP/Contents/MacOS/Hush"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hush</string>
  <key>CFBundleDisplayName</key><string>Hush</string>
  <key>CFBundleIdentifier</key><string>com.abiodun.hush</string>
  <key>CFBundleExecutable</key><string>Hush</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
