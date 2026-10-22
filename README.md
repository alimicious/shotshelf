# ShotShelf

A Liquid Glass menu bar shelf for your recent screenshots. Click the polaroid (or press **⌥⌘S** anywhere) to see your newest shot big and the six before it below. Drag a shot into any app to share it, onto another shot to rearrange, or onto a folder chip to file it away.

- **Hover a shot** to copy the image, copy its text (on-device OCR), Quick Look it, or open the ⋯ menu for float on screen, share, pin, mark up, rename from text, move to a folder, show in Finder and Trash. Right-click does the same.
- **Links and QR codes**: when a shot's text has a web link or an email address, or the shot has a QR code, a button for it joins the hover controls (open the link, copy the address or what the code says), and the ⋯ menu lists them all.
- **Select several** with ⌘-click or ⇧-click (or ⌘A). The footer then copies, shares, pins, files or trashes them together, and its "selected" stack drags them all into another app or onto a folder chip.
- **Undo**: moving shots to the Trash, by hand or with Tidy, shows an Undo button (or press ⌘Z) that puts them back, pins and all.
- **Keyboard**: arrows move, Space previews, ⌘C copies, T copies text, P pins, R marks up, F floats, ⌫ trashes, ⌘Z undoes a trash, ⌘A selects all, ⌘F searches, Esc clears the selection, then closes.
- **Mark up** opens an editor with arrows, boxes, highlights, text in five colours and Redact, which pixelates private bits. It saves a copy next to the original ("(marked up)", or "(redacted)" if all you did was redact).
- **Float on screen** keeps a shot in a small glass frame above your other windows, on every Space, to refer to while you work. Drag it to move it, pinch or drag an edge to resize it, and hover for see-through, copy and close. Esc closes it.
- **Share** sends shots with AirDrop, Messages, Mail and the rest of the macOS share menu.
- **Smart names**: new screenshots are renamed from their text and the app you were in, like "Xcode – Build Failed 20.02.png". Turn it off in Settings.
- **Show all** (grid button or ⌘F) opens in its own panel beside the shelf, lists every screenshot and searches the text inside them. Press ↓ to move from the search field into the results, then use the arrow keys, Space to preview and the other shelf keys; typing carries on the search. Click a shot's eye to see it bigger, or drag it onto one of the shelf's tiles to put it there.
- **Capture sizes**: a Spotlight-style glass bar floats under the shelf. Save up to 20 sizes with its round + button, then click one in the bar (it scrolls sideways once they don't all fit). Clicking one dims the screen like ⌘⇧5 with a frame of exactly that size; drag it into place and press Capture. This needs Screen Recording permission, which macOS asks for the first time. Releases are signed with the same certificate every time, so the permission carries over to new versions.
- **Shortcuts**: record your own in Settings for opening the shelf (⌥⌘S by default) and for jumping straight to search.
- **Sizes**: Small, Medium or Large in Settings. Bigger panels get bigger tiles and more of them (4, 7 or 13 shots).
- **Tidy** moves unpinned shots from before today to the Trash, with Undo; auto-tidy can do it on a schedule.
- **New shots** make the menu bar polaroid flash, then a fresh photo slides up and develops, and a count of new shots sits beside it until you open the shelf. The animation can be turned off in Settings.

It reads the folder macOS saves screenshots to (the Desktop unless you changed it), top level only, and goes by the tag macOS puts on every screenshot, so other images are never touched. Nothing is deleted outright; it all goes to the Trash. Everything stays on your Mac: the only network request is a daily check of GitHub for a newer version, which you can turn off in Settings.

**Updates** install from inside the app: when a new version is out, an **Update** pill appears in the panel's header, and one click downloads it, checks it, and relaunches into it. Each release zip is signed, and the app only installs zips that match the public key built into it.

## Install

Requires macOS 26 or later. Runs on Apple Silicon and Intel Macs.

1. Download the latest **ShotShelf zip** from the [Releases page](https://github.com/alimicious/shotshelf/releases/latest) and double-click it to unzip.
2. Drag **ShotShelf** into your **Applications** folder and open it.
3. macOS will say it can't verify the app, because it isn't notarized by Apple. Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.
4. When ShotShelf asks to access your Desktop (or wherever your screenshots are saved), click **Allow**.

The first time it opens, a short welcome explains the basics, and macOS asks for access to your screenshots once you click **Get Started**. After that, click the polaroid in your menu bar or press ⌥⌘S. To start it automatically, open settings (the gear) and turn on **Launch at login**.

## Build from source

Requires the Swift toolchain (the Xcode Command Line Tools are enough).

```bash
./build.sh                       # builds build/ShotShelf.app for this Mac
./build.sh --install             # also copies it to /Applications and launches it
./build.sh --universal           # builds for both Apple Silicon and Intel
./release.sh                     # builds a universal zip, signs it, and publishes a GitHub release for ./VERSION
```

`release.sh` signs each zip with a private key stored in the maintainer's Keychain as "ShotShelf update signing key" and uploads the signature next to the zip. The matching public key is in `Updater.swift`. Keep a backup of the private key (Keychain Access → that item → Show password, into a password manager): without it, installed copies can't verify future updates.

Debug flags: `--dump` lists screenshots and tests OCR and link detection, `--render out.png [--size small|medium|large] [--welcome] [--select]` saves an image of the panel, `--render-icons out.png` the menu bar icon frames, `--render-markup in.png out.png` draws one of each mark on a shot, `--selftest` opens the panel and Quick Look and reports what happened, and `--selftest-actions` tries trash and undo, selection, links, floating and markup. Add `--folder <dir>` to run any of them on sample screenshots instead of your own (`--selftest-actions` requires it, since it moves shots to the Trash and back). The app icon is drawn in code too: `build.sh` runs `ShotShelf --iconset` and packs the result with `iconutil`.
