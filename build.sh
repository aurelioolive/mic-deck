#!/bin/zsh
set -e
HERE="${0:A:h}"
APP_NAME="Mic Deck"
BUNDLE_ID="local.micdeck"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>MicDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>The level meter shows the captured signal while the menu is open.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xcrun swiftc -O \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework Carbon \
  -o "$APP/Contents/MacOS/MicDeck" \
  "$HERE/Sources/main.swift"

codesign --force --deep --sign - "$APP"
echo "built: $APP"
