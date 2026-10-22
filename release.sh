#!/bin/bash
# Builds a universal ShotShelf.app, zips it, and publishes it as a GitHub release
# tagged with the version in ./VERSION. Bump VERSION and commit before running.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
TAG="v$VERSION"
ZIP="build/ShotShelf-$VERSION.zip"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit your changes before releasing." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists; bump VERSION first." >&2
    exit 1
fi
# Installed copies only accept updates signed with this key, which lives in this Mac's Keychain.
KEY_NAME="ShotShelf update signing key"
if ! security find-generic-password -s "$KEY_NAME" >/dev/null 2>&1; then
    echo "No \"$KEY_NAME\" in your Keychain, so the update can't be signed." >&2
    exit 1
fi

./build.sh --universal
rm -f "$ZIP"
# Leave out macOS file metadata (extended attributes) so the zip carries nothing about this Mac.
ditto -c -k --norsrc --noextattr --keepParent build/ShotShelf.app "$ZIP"
# The key goes in through stdin, so it never shows up in a command line or the process list.
security find-generic-password -s "$KEY_NAME" -w | build/ShotShelf.app/Contents/MacOS/ShotShelf --sign-update "$ZIP" > "$ZIP.sig"
build/ShotShelf.app/Contents/MacOS/ShotShelf --verify-update "$ZIP" "$ZIP.sig"

git push
gh release create "$TAG" "$ZIP" "$ZIP.sig" --target "$(git rev-parse HEAD)" --title "ShotShelf $VERSION" --notes-file - <<NOTES
A Liquid Glass menu bar shelf for your screenshots. Your newest shot shows up big with the six before it underneath: drag one into any app to share it, onto another shot to rearrange, or onto a folder chip to file it away.

- **Copy the image or the text in it** (read on your Mac with Apple's Vision), Quick Look, pin, redact private bits, or send to the Trash.
- **⌥⌘S** opens the shelf from anywhere, and you can record your own shortcuts for it and for jumping straight to search. Inside, arrows move, Space previews, ⌘C copies, ⌫ trashes and Esc closes.
- **Smart names:** new screenshots are renamed from their text and the app you were in, like "Xcode – Build Failed 20.02.png". You can turn this off in settings (the gear).
- **Search** every screenshot by the words inside it, then drag results onto the shelf or click the eye to see them bigger.
- **Small, Medium or Large** panel: bigger panels show bigger tiles and more of them.
- **Capture sizes:** save up to four sizes in the Spotlight-style bar under the shelf, then click one to capture exactly that area.
- **Tidy** sends unpinned shots from before today to the Trash, by hand or on a schedule.
- A little pixel mascot snaps a photo in your menu bar whenever you take a screenshot.

## Install

1. Download **ShotShelf-$VERSION.zip** below and double-click it to unzip.
2. Drag **ShotShelf** into your **Applications** folder and open it.
3. macOS will say it can't verify the app, because it isn't notarized by Apple. Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.
4. When ShotShelf asks to access your Desktop (or wherever your screenshots are saved), click **Allow**.

Then click the polaroid in your menu bar, or press ⌥⌘S.

Requires macOS 26 or later. Runs on Apple Silicon and Intel Macs. Everything stays on your Mac: ShotShelf only reads your screenshot folder, and its one network request is a daily check of GitHub for a newer version (you can turn it off in settings). Updates install from inside the app and are signed, so only genuine releases are accepted. Anything ShotShelf removes goes to the Trash, so it can always be put back.

*Unofficial fan project, not affiliated with or endorsed by Anthropic.*
NOTES
