#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Halfwin.app"
BIN="Halfwin"
BUNDLE_ID="com.dhrlabs.halfwin"
VERSION="${1:-0.1.0}"

echo "Compiling…"
swift build -c release

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>Halfwin</string>
    <key>CFBundleDisplayName</key>         <string>Halfwin</string>
    <key>CFBundleExecutable</key>          <string>$BIN</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key> <string>Halfwin sets Finder windows to list view.</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }' || true)"
if [ -n "$IDENTITY" ]; then
    echo "Signing with Apple Development identity…"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "No Apple Development identity found; using ad-hoc signing…"
    codesign --force --deep --sign - "$APP"
fi

echo "Done → $(pwd)/$APP"
