# ShotShelf: notes for working on it

A macOS 26+ menu bar app (Swift package, SwiftUI + AppKit) for recent screenshots. Read README.md
first for what it does. This file covers how to work on it.

## Layout

- `ShotShelfApp.swift`: entry point, `Prefs` keys, and all debug/build flags.
- `StatusController.swift`: the menu bar item and every window (shelf panel, search panel, capture
  bar). Built by hand because MenuBarExtra can't be opened from code (the global shortcut needs that).
- `ShelfStore.swift`: all state and actions (scanning, keys, tidy, presets, capture, updates).
- `ShelfView.swift` (shelf, settings, update popover), `AllShotsView.swift` (search),
  `PresetCapture.swift` (capture bar, preset editor, capture overlay), `Redactor.swift`,
  `Updater.swift`, `HotKey.swift` (shortcuts, panel sizes, app delegate + Quick Look),
  `ShotScanner.swift` (folder scan, OCR, smart names), `ShelfIcon.swift`, `AppIcon.swift`.

## Toolchain quirks (this Mac has only the Command Line Tools)

- `@State` and `#Preview` don't compile (no macro plugin). Keep state in the `ShelfStore`
  ObservableObject. `@AppStorage`, `@FocusState`, `@ObservedObject` and `@Environment` work.
- No screen access for checking UI. Use the debug flags instead:
  - `--render out.png [--size small|medium|large] [--extras]`: the shelf, via ImageRenderer. It can't
    draw glass, blur, scroll views or native buttons (they come out blank or as placeholders).
  - `--render-bar out.png`, `--render-icons out.png`: the capture bar, the sweep and the icons.
  - `--selftest`: opens the real panels on screen and prints window frames, the editor morph, search
    and Quick Look. If the user clicks elsewhere during it, the shelf closes (by design) and later
    checks read wrong; just re-run.
  - `--dump`: lists screenshots and tests OCR.
- Glass windows: borderless `ShelfPanel`s with `NSGlassEffectView`s inside
  `NSGlassEffectContainerView`s, no window shadow, `ignoresMouseEvents = false` and a 1% backing so
  clicks don't fall through on macOS 26.

## Build, install, release

- `./build.sh --install` builds, signs and installs to /Applications. Bump `VERSION` for releases.
- Builds are signed with the **"ShotShelf Code Signing"** certificate in the maintainer's login
  Keychain (self-signed, shows as not trusted, that's fine). A stable identity keeps Screen
  Recording and Desktop permissions across updates; ad-hoc signing loses them on every update.
- `./release.sh` (needs a clean tree) builds universal, signs the zip with the **"ShotShelf update
  signing key"** (Ed25519, in the Keychain; the public half is in `Updater.swift`), uploads zip + `.sig`
  and creates the GitHub release. Afterwards: prepend a "New in x.y.z" paragraph to the notes with
  `gh release edit`, download the release back, verify the signature, `codesign --verify`, and run
  `--test-update https://api.github.com/repos/alimicious/shotshelf/releases/latest <dir>` from the
  previous published version to confirm in-app updates still work.
- Never print, copy into the repo, or commit either private key or the certificate's key.

## Privacy (the repo and releases are public)

Before every commit and release, scan the diff and the downloaded release for the maintainer's
username, home-folder paths, email, project folder names and secrets. Commits use the GitHub noreply
author configured in this repo. Debug symbols are stripped in `build.sh` because they embed absolute
source paths.

## Working with the maintainer

- Hands-on and visual; wants Apple-level polish and Liquid Glass consistency.
- Builds, installs and pushes are expected after each change; only publish a release when asked
  ("bump to x.y.z and publish"). Commit messages end with a Co-Authored-By line.
