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

./build.sh --universal
rm -f "$ZIP"
# Leave out macOS file metadata (extended attributes) so the zip carries nothing about this Mac.
ditto -c -k --norsrc --noextattr --keepParent build/ShotShelf.app "$ZIP"

git push
gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" --title "ShotShelf $VERSION" --notes-file - <<NOTES
A Liquid Glass menu bar shelf for your screenshots. Your newest shot shows up big with the six before it underneath: drag one into any app to share it, onto another shot to rearrange, or onto a folder chip to file it away.

- **Copy the image or the text in it** (read on your Mac with Apple's Vision), Quick Look, pin, redact private bits, or send to the Trash.
- **⌥⌘S** opens the shelf from anywhere. Inside, arrows move, Space previews, ⌘C copies, ⌫ trashes and Esc closes.
- **Smart names:** new screenshots are renamed from their text and the app you were in, like "Xcode – Build Failed 20.02.png". You can turn this off in settings (the gear).
- **Search** every screenshot by the words inside it.
- **Tidy** sends unpinned shots from before today to the Trash, by hand or on a schedule.
- A little pixel mascot snaps a photo in your menu bar whenever you take a screenshot.

## Install

1. Download **ShotShelf-$VERSION.zip** below and double-click it to unzip.
2. Drag **ShotShelf** into your **Applications** folder and open it.
3. macOS will say it can't verify the app, because it isn't notarized by Apple. Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.
4. When ShotShelf asks to access your Desktop (or wherever your screenshots are saved), click **Allow**.

Then click the polaroid in your menu bar, or press ⌥⌘S.

Requires macOS 26 or later. Runs on Apple Silicon and Intel Macs. Everything stays on your Mac: ShotShelf only reads your screenshot folder and never connects to the internet. Anything it removes goes to the Trash, so it can always be put back.

*Unofficial fan project, not affiliated with or endorsed by Anthropic.*
NOTES
