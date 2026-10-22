#!/bin/bash
# Builds ShotShelf.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/ShotShelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ShotShelf "$APP/Contents/MacOS/ShotShelf"

# The app draws its own icon; iconutil packs the sizes into an .icns.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$APP/Contents/MacOS/ShotShelf" --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ShotShelf</string>
    <key>CFBundleDisplayName</key><string>ShotShelf</string>
    <key>CFBundleIdentifier</key><string>com.alimicious.shotshelf</string>
    <key>CFBundleExecutable</key><string>ShotShelf</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ShotShelf && sleep 1 || true  # give the old copy time to quit before relaunching
    rm -rf /Applications/ShotShelf.app
    cp -R "$APP" /Applications/
    open /Applications/ShotShelf.app
    echo "Installed to /Applications and launched"
fi
