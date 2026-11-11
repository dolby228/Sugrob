#!/usr/bin/env bash
# Build Sugrob in release mode and wrap the binary into dist/Sugrob.app.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="dist/Sugrob.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sugrob" "$APP/Contents/MacOS/Sugrob"

# App icon: drawn by scripts/make-icon.swift, packed with iconutil.
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/AppIcon.iconset"
if ! swift scripts/make-icon.swift "$ICONSET"; then
    echo "error: icon generation failed (scripts/make-icon.swift)" >&2
    exit 1
fi
if ! iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "error: iconutil could not build AppIcon.icns" >&2
    exit 1
fi
if [[ ! -s "$APP/Contents/Resources/AppIcon.icns" ]]; then
    echo "error: AppIcon.icns is missing or empty" >&2
    exit 1
fi
echo "Generated icon: $(stat -f%z "$APP/Contents/Resources/AppIcon.icns") bytes"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sugrob</string>
    <key>CFBundleDisplayName</key><string>Sugrob</string>
    <key>CFBundleIdentifier</key><string>dev.sugrob.app</string>
    <key>CFBundleExecutable</key><string>Sugrob</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets the user open it via right click -> Open.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
