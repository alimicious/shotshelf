#!/bin/bash
# Builds ShotShelf.app into ./build.
#   --universal  build for both Apple Silicon and Intel Macs (used for releases)
#   --install    copy the app to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

ARCH_FLAGS=""
if $UNIVERSAL; then ARCH_FLAGS="--arch arm64 --arch x86_64"; fi
swift build -c release $ARCH_FLAGS
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

APP=build/ShotShelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ShotShelf" "$APP/Contents/MacOS/ShotShelf"
# Drop debug symbols: they record the build machine's absolute source paths (home folder included).
strip -S -x "$APP/Contents/MacOS/ShotShelf"

# The app draws its own icon; iconutil packs the sizes into an .icns.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$APP/Contents/MacOS/ShotShelf" --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with the "ShotShelf Code Signing" certificate from this Mac's Keychain when it's there: macOS
# then sees every build as the same app, so permissions (Screen Recording, Desktop access) survive
# updates. An ad-hoc signature, the fallback when building from source elsewhere, is a fingerprint of
# one exact build, so macOS treats each update as a new app and asks again.
IDENTITY="ShotShelf Code Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    # The Keychain occasionally refuses the first request, so try twice.
    codesign --force --sign "$IDENTITY" "$APP" || codesign --force --sign "$IDENTITY" "$APP"
else
    echo "No \"$IDENTITY\" certificate in the Keychain; signing ad hoc (permissions won't survive updates)." >&2
    codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/ShotShelf"))"

if $INSTALL; then
    pkill -x ShotShelf && sleep 1 || true  # give the old copy time to quit before relaunching
    rm -rf /Applications/ShotShelf.app
    cp -R "$APP" /Applications/
    open /Applications/ShotShelf.app
    echo "Installed to /Applications and launched"
fi
