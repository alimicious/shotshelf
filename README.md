# ShotShelf

A Liquid Glass menu bar shelf for your recent screenshots. Click the polaroid (or press **⌥⌘S** anywhere) to see your newest shot big and the six before it below. Drag a shot into any app to share it, onto another shot to rearrange, or onto a folder chip to file it away.

- **Hover a shot** to copy the image, copy its text (on-device OCR), Quick Look it, or open the ⋯ menu for pin, redact, rename from text, move to a folder, show in Finder and Trash. Right-click does the same.
- **Keyboard**: arrows move, Space previews, ⌘C copies, T copies text, P pins, R redacts, ⌫ trashes, ⌘F searches, Esc closes.
- **Redact** opens an editor where you drag boxes over private bits; it saves a pixelated copy next to the original.
- **Smart names**: new screenshots are renamed from their text and the app you were in, like "Xcode – Build Failed 20.02.png". Turn it off in Settings.
- **Show all** (grid button or ⌘F) lists every screenshot and searches the text inside them.
- **Tidy** moves unpinned shots from before today to the Trash; auto-tidy can do it on a schedule.
- The pixel mascot pops up and snaps a photo whenever you take a screenshot.

It reads the folder macOS saves screenshots to (the Desktop unless you changed it), top level only, and goes by the tag macOS puts on every screenshot, so other images are never touched. Nothing is deleted outright; it all goes to the Trash. Requires macOS 26.

```bash
./build.sh --install   # build, install to /Applications and launch
```

Debug flags: `--dump` lists screenshots and tests OCR, `--render out.png` saves an image of the panel, `--render-icons out.png` the menu bar icon frames, and `--selftest` opens the panel and Quick Look and reports what happened.
