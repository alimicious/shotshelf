# ShotShelf

A Liquid Glass menu bar shelf for your recent screenshots. Click the polaroid (or press **⌥⌘S** anywhere) to see your newest shot big and the six before it below. Drag a shot into any app to share it, onto another shot to rearrange, or onto a folder chip to file it away.

- **Pop-up after each capture**: while the shelf is closed, a new screenshot drops out of the menu bar as a small glass card for a few seconds (longer while you hover it), with copy, copy text, mark up, float and Trash. Drag the shot straight from it into any app, or click it to open the shelf. Turn it off in Settings.
- **Hover a shot** to copy the image, copy its text (on-device OCR), Quick Look it, or open the ⋯ menu for copy with background, copy subject, float on screen, share, pin, mark up, redact private info, translate, rename from text, move to a folder, show in Finder and Trash. Right-click does the same.
- **Links and QR codes**: when a shot's text has a web link or an email address, or the shot has a QR code, a button for it joins the hover controls (open the link, copy the address or what the code says), and the ⋯ menu lists them all.
- **Select several** with ⌘-click or ⇧-click (or ⌘A). The footer then copies, shares, pins, files or trashes them together, combines them into one image side by side or stacked, and its "selected" stack drags them all into another app or onto a folder chip.
- **Undo**: moving shots to the Trash, by hand or with Tidy, shows an Undo button (or press ⌘Z) that puts them back, pins and all.
- **Keyboard**: arrows move, Space previews, ⌘C copies, T copies text, P pins, R marks up, F floats, ⌫ trashes, ⌘Z undoes a trash, ⌘A selects all, ⌘F searches, Esc clears the selection, then closes.
- **Mark up** opens an editor with arrows, boxes, highlights, text in five colours and Redact, which blacks out private bits (solid black rather than pixelation, which can be reversed). Its wand finds and redacts private details for you (email addresses, phone and card numbers, IBANs, API keys, tokens and passwords; best effort, so check before sharing), and its frame button sets the shot on a soft gradient with rounded corners and a shadow, for sharing. It saves a copy next to the original ("(marked up)", or "(redacted)" if all you did was redact).
- **Copy with Background** copies a shot on the gradient last picked in markup, in one click. **Copy Subject** lifts the main subject (a person, pet or object in a photo) out of its background. **Translate Text** opens Apple's on-device translation of the shot's text.
- **Float on screen** keeps a shot in a small glass frame above your other windows, on every Space, to refer to while you work. Drag it to move it, pinch or drag an edge to resize it, and hover for Live Text (select and copy its text, open links, look things up), see-through, copy and close. Esc closes it.
- **Share** sends shots with AirDrop, Messages, Mail and the rest of the macOS share menu.
- **Smart names**: new screenshots are renamed from their text and the app you were in, like "Xcode – Build Failed 20.02.png". Turn it off in Settings.
- **Show all** (grid button or ⌘F) opens in its own panel beside the shelf, lists every screenshot and searches the text inside them. Press ↓ to move from the search field into the results, then use the arrow keys, Space to preview and the other shelf keys; typing carries on the search. Click a shot's eye to see it bigger, or drag it onto one of the shelf's tiles to put it there.
- **Capture sizes**: a Spotlight-style glass bar floats under the shelf. Save up to 20 sizes with its round + button, then click one in the bar (it scrolls sideways once they don't all fit). Clicking one dims the screen like ⌘⇧5 with a frame of exactly that size; drag it into place and press Capture. The viewfinder at the start of the bar also captures a window (click one; it keeps its shadow), captures the same area again, and turns on a 3-second timer so you can open a menu first. This needs Screen Recording permission, which macOS asks for the first time. Releases are signed with the same certificate every time, so the permission carries over to new versions.
- **Screen recordings** (⌘⇧5) sit on the shelf too, with a play badge and their length. Trim one with the system's trim bar and save the trimmed part, or save it as a GIF in one of three widths.
- **Shortcuts**: record your own in Settings for opening the shelf (⌥⌘S by default), jumping straight to search, and copying, copying the text of or floating the newest screenshot without opening anything.
- **Sizes**: Small, Medium or Large in Settings. Bigger panels get bigger tiles and more of them (4, 7 or 13 shots).
- **Tidy** moves unpinned shots from before today, and near-copies of newer shots (found on-device by how they look), to the Trash, with Undo; auto-tidy can clear old ones on a schedule.
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

Debug flags exist only in debug builds (`swift build`, then run `.build/debug/ShotShelf`), since they read shots with ShotShelf's own permissions: `--dump` lists screenshots and tests OCR and link detection, `--render out.png [--size small|medium|large] [--welcome] [--select]` saves an image of the panel, `--render-icons out.png` the menu bar icon frames, `--render-markup in.png out.png` draws one of each mark on a shot, `--render-orb out.png` the gradient orb at several moments, `--private shot.png` lists what Redact Private Info would hide, `--fingerprints` prints how alike same-size shots look, `--selftest` opens the panel and Quick Look and reports what happened, and `--selftest-actions` tries trash and undo, selection, links, floating, markup, private-info redaction, duplicates, combining, translation, the pop-up, the newest-shot shortcuts and recordings. Add `--folder <dir>` to run any of them on sample screenshots instead of your own (`--selftest-actions` requires it, since it moves shots to the Trash and back). The app icon is drawn in code too: `build.sh` runs `ShotShelf --iconset` and packs the result with `iconutil`.
