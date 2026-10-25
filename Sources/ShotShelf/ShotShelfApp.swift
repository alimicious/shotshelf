import AVFoundation
import Carbon.HIToolbox
import CryptoKit
import Quartz
import SwiftUI

/// UserDefaults keys shared between the store and @AppStorage in the views.
enum Prefs {
    static let pinned = "pinned"              // [String] file paths
    static let lastSeen = "lastSeen"          // Double, when the panel was last opened
    static let autoTidyDays = "autoTidyDays"  // Int, 0 = off
    static let order = "order"                // [String] file paths, as you last arranged them
    static let folders = "folders"            // [String] folder paths shown as chips
    static let hotKey = "hotKey"              // String, the old fixed shortcut choice (migrated to openShortcut)
    static let openShortcut = "openShortcut"  // JSON Shortcut, or null when cleared
    static let searchShortcut = "searchShortcut"
    static let panelSize = "panelSize"        // PanelSize raw value
    static let autoUpdates = "autoUpdates"    // Bool, check GitHub for a newer version once a day
    static let lastUpdateCheck = "lastUpdateCheck"  // Double, when that last happened
    static let capturePresets = "capturePresets"    // JSON [CapturePreset]
    static let searchEyes = "searchEyes"            // Bool, show the eye buttons on search results
    static let smartNames = "smartNames"      // Bool, rename new shots from their text
    static let iconAnimation = "mascot"       // Bool, animate the menu bar icon for new shots (stored under its old name)
    static let welcomed = "welcomed"          // Bool, the first-launch card has been dismissed
    static let markupTool = "markupTool"      // MarkTool raw value, the last one used
    static let markupBackdrop = "markupBackdrop"  // Backdrop raw value, the last background picked
    static let copyNewestShortcut = "copyNewestShortcut"          // JSON Shortcut, or null
    static let copyNewestTextShortcut = "copyNewestTextShortcut"
    static let floatNewestShortcut = "floatNewestShortcut"
    static let capturePopup = "capturePopup"  // Bool, show the pop-up after each capture
    static let captureTimer = "captureTimer"  // Bool, captures wait three seconds
}

@main
struct ShotShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Build flag: `--iconset <dir>` writes the app icon PNGs (see build.sh).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--iconset"), i + 1 < args.count {
            do {
                try AppIcon.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch {
                print("Couldn't write iconset: \(error)")
                exit(1)
            }
        }
        #if DEBUG
        // Debug flags, in debug builds only (`swift build`, then `.build/debug/ShotShelf --dump`): they
        // read shots with ShotShelf's own Desktop and Screen Recording access and write wherever they're
        // told, so in a release build any app could launch it with them to borrow that access.
        // `--dump` lists the screenshots found, `--render <file.png> [--size small|medium|large]
        // [--extras] [--welcome] [--select] [--undo-toast]` saves the panel, `--render-markup <in.png> <out.png>`
        // draws one of each mark on a shot, `--selftest` opens the panel and Quick Look on screen and reports
        // what happened, and `--selftest-actions` tries trash and undo, selection, links, floating and markup.
        // `--folder <dir>` points any of them at sample shots instead of your screenshot folder.
        if let i = args.firstIndex(of: "--folder"), i + 1 < args.count {
            ShotScanner.testFolder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            Self.renderPanel(to: args[i + 1])
            exit(0)
        }
        if args.contains("--dump") {
            let folder = ShotScanner.folder
            guard let shots = ShotScanner.scan(folder) else { print("can't read \(folder.path)"); exit(1) }
            print("\(shots.count) screenshots in \(folder.path)")
            for s in shots { print("  \(s.date.formatted(date: .abbreviated, time: .shortened))  \(s.url.lastPathComponent)") }
            if let first = shots.first {
                let lines = ShotText.recognize(first.url)
                print("text in newest: \(lines.count) lines")
                print("smart name: \(ShotText.smartName(lines, app: nil, date: first.date) ?? "none")")
                let links = ShotText.links(text: lines.map(\.text).joined(separator: "\n"), codes: ShotText.codes(first.url))
                print("quick actions: \(links.map(\.title))")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--private"), i + 1 < args.count {
            // What Redact Private Info would hide in a shot.
            let start = Date()
            let areas = ShotTools.privateAreas(URL(fileURLWithPath: args[i + 1]))
            print("\(areas.count) private details in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            for area in areas { print("  x \(String(format: "%.2f", area.minX)) y \(String(format: "%.2f", area.minY)) w \(String(format: "%.2f", area.width))") }
            exit(0)
        }
        if args.contains("--fingerprints") {
            // How alike each pair of same-size shots looks, to tune what counts as a duplicate.
            let prints = (ShotScanner.scan(ShotScanner.folder) ?? []).filter { !$0.isVideo }.compactMap { shot in
                ShotTools.fingerprint(shot.url).map { (shot.url.lastPathComponent, $0) }
            }
            for i in prints.indices {
                for j in prints.indices where j > i {
                    guard let d = ShotTools.distance(prints[i].1, prints[j].1) else { continue }
                    print(String(format: "%.3f", d), d < ShotTools.duplicateDistance ? "duplicate" : "different",
                          prints[i].0, "|", prints[j].0)
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-markup"), i + 2 < args.count {
            Self.renderMarkup(args[i + 1], to: args[i + 2])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-icons"), i + 1 < args.count {
            Self.renderIcons(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-orb"), i + 1 < args.count {
            Self.renderOrb(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-bar"), i + 1 < args.count {
            Self.renderBar(to: args[i + 1])
            exit(0)
        }
        if args.contains("--selftest") { Self.selfTest() }
        if args.contains("--selftest-actions") { Self.selfTestActions() }
        #endif

        // Release flags (see release.sh): `--generate-update-key` prints a new private key then its
        // public key, `--sign-update <zip>` signs with the private key read from stdin,
        // `--verify-update <zip> <sig>` checks a signature, and `--test-update <feed.json or URL> <dir>
        // [--pretend-version x]` runs a whole update from a local feed into <dir>/ShotShelf.app.
        if args.contains("--generate-update-key") {
            let key = Curve25519.Signing.PrivateKey()
            print(key.rawRepresentation.base64EncodedString())
            print(key.publicKey.rawRepresentation.base64EncodedString())
            exit(0)
        }
        if let i = args.firstIndex(of: "--sign-update"), i + 1 < args.count {
            let privateKey = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            guard let zip = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
                  let signature = try? Updater.sign(zip, privateKey: privateKey) else { print("Couldn't sign"); exit(1) }
            print(signature)
            exit(0)
        }
        if let i = args.firstIndex(of: "--verify-update"), i + 2 < args.count {
            let zip = (try? Data(contentsOf: URL(fileURLWithPath: args[i + 1]))) ?? Data()
            let signature = (try? Data(contentsOf: URL(fileURLWithPath: args[i + 2]))) ?? Data()
            let valid = Updater.verify(zip, signature: signature)
            print(valid ? "signature ok" : "signature INVALID")
            exit(valid ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--test-update"), i + 2 < args.count {
            let pretend = args.firstIndex(of: "--pretend-version").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let feed = args[i + 1].hasPrefix("https://") ? URL(string: args[i + 1])! : URL(fileURLWithPath: args[i + 1])
            Self.testUpdate(feed: feed, into: URL(fileURLWithPath: args[i + 2]),
                            current: pretend ?? Updater.currentVersion)
        }
    }

    private static func testUpdate(feed: URL, into dir: URL, current: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                guard let update = try await Updater.check(feed: feed, current: current) else {
                    print("no signed update newer than \(current)")
                    exit(0)
                }
                print("found \(update.version)")
                let target = dir.appendingPathComponent("ShotShelf.app")
                let app = try await Updater.prepare(update, nextTo: target)
                print("downloaded and verified")
                try Updater.install(app, replacing: target)
                print("installed into \(dir.lastPathComponent)")
            } catch {
                print("update failed: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    #if DEBUG
    @MainActor private static func renderPanel(to path: String) {
        let store = ShelfStore(preview: ShotScanner.scan(ShotScanner.folder) ?? [])
        store.hovered = store.shots.first?.url  // show the hover actions on one cell
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--size"), i + 1 < args.count, let size = PanelSize(rawValue: args[i + 1].capitalized) {
            store.panelSize = size
        }
        if args.contains("--extras") { store.addPreviewExtras() }
        if args.contains("--welcome") { store.showPreviewWelcome() }
        if args.contains("--select") { store.selectAll(Array(store.visible.prefix(3))) }
        if args.contains("--undo-toast") { store.showToast("Moved 3 to the Trash", symbol: "trash", undo: true) }
        let renderer = ImageRenderer(content: ShelfView(store: store)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// One mark of each kind on a shot, saved the way the editor's Save Copy would save it.
    @MainActor private static func renderMarkup(_ input: String, to path: String) {
        guard let model = MarkupModel(shot: Shot(url: URL(fileURLWithPath: input), date: Date())) else {
            print("Couldn't open \(input)")
            exit(1)
        }
        model.marks = [
            Mark(tool: .redact, start: CGPoint(x: 0.04, y: 0.05), end: CGPoint(x: 0.4, y: 0.2), color: 0),
            Mark(tool: .highlight, start: CGPoint(x: 0.04, y: 0.28), end: CGPoint(x: 0.62, y: 0.38), color: 2),
            Mark(tool: .box, start: CGPoint(x: 0.56, y: 0.5), end: CGPoint(x: 0.95, y: 0.9), color: 0),
            Mark(tool: .arrow, start: CGPoint(x: 0.2, y: 0.88), end: CGPoint(x: 0.53, y: 0.66), color: 1),
            Mark(tool: .text, start: CGPoint(x: 0.06, y: 0.5), end: CGPoint(x: 0.06, y: 0.5), color: 3, text: "Look here"),
            Mark(tool: .text, start: CGPoint(x: 0.6, y: 0.05), end: CGPoint(x: 0.6, y: 0.05), color: 4, text: "White text"),
        ]
        guard let data = model.render() else {
            print("Couldn't render")
            exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// The menu bar icon at rest and then every frame of its new-shot animation, with and without
    /// Reduce Motion, on a dark and a light strip.
    @MainActor private static func renderIcons(to path: String) {
        let rows = [false, true].map { reduceMotion in
            [ShelfIcon.Frame.rest] + IconAnimator.steps(reduceMotion: reduceMotion).map(\.0)
        }
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            ForEach([Color.black, Color(white: 0.92)], id: \.self) { bg in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 10) {
                            ForEach(rows[row].indices, id: \.self) { i in
                                Image(nsImage: ShelfIcon.image(size: 40, frame: rows[row][i])).renderingMode(.template)
                                    .foregroundStyle(bg == .black ? .white : .black)
                            }
                        }
                    }
                }
                .padding(20).background(bg)
            }
        })
        renderer.scale = 1
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The orb big at four moments of its drift (seconds apart), and at the sizes the app uses,
    /// on light and dark.
    @MainActor private static func renderOrb(to path: String) {
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            ForEach([Color(white: 0.96), Color(white: 0.12)], id: \.self) { bg in
                HStack(spacing: 24) {
                    ForEach([0.0, 4, 8, 12], id: \.self) { t in OrbMark(size: 180, time: t) }
                    VStack(spacing: 16) {
                        OrbMark(size: 88, time: 0)
                        OrbMark(size: 52, time: 0)
                        OrbMark(size: 34, time: 0)
                    }
                }
                .padding(28).background(bg)
            }
        })
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The capture bar's capsule with 2 and with 20 sizes, and the Update pill's light band frozen
    /// at three points of its sweep, on a stand-in pill (the renderer can't draw glass).
    @MainActor private static func renderBar(to path: String) {
        func bar(_ count: Int) -> some View {
            let store = ShelfStore(preview: [])
            store.setPreviewPresets(count)
            return CaptureBarView(store: store)
                .frame(width: 298, height: 52)
                .background(Capsule().fill(Color(white: 0.2)))
        }
        let pill = Label("Update", systemImage: "arrow.down.circle.fill").font(.callout.weight(.semibold))
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color(nsColor: ShelfIcon.terracotta)))
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 14) {
            bar(2)
            bar(20)
            HStack(spacing: 14) {
                ForEach([0.1, 0.4, 0.75], id: \.self) { p in pill.overlay { SweepBand(position: p) } }
            }
        }
        .padding(20)
        .background(Color(white: 0.1))
        .environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func selfTest() {
        func visibleWindows() -> String {
            NSApp.windows.filter(\.isVisible)
                .map { "\($0.className) x=\(Int($0.frame.minX))…\(Int($0.frame.maxX)) \(Int($0.frame.width))×\(Int($0.frame.height))" }
                .joined(separator: ", ")
        }
        func after(_ seconds: Double, _ step: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: step)
        }
        let controller = { AppDelegate.shared?.statusController }
        after(2) {
            controller()?.toggle()
            after(1.5) {
                print("after toggle: \(visibleWindows())")
                print("open shortcut registered: \(controller()?.store.hotKeyRegistered ?? false)")
                print("shelf: \(controller()?.panelSummary ?? "-")")
                print("bar at rest: \(controller()?.barSummary ?? "-")")
                controller()?.store.newPreset()
                after(0.9) {
                    print("editor open: \(controller()?.barSummary ?? "-")")
                    controller()?.store.presetEditor = nil
                    after(0.8) {
                        print("editor closed: \(controller()?.barSummary ?? "-")")
                        controller()?.close()
                        controller()?.store.openSearch()
                        after(1.5) {
                            print("after search shortcut: \(visibleWindows())")
                            // Quick Look from search should leave search (and the shelf) open.
                            if let store = controller()?.store, let first = store.searchResults.first {
                                store.quickLook(first, among: store.searchResults, follow: { store.searchSelection = $0 })
                            }
                            after(1.5) {
                                let panel = QLPreviewPanel.shared()
                                print("quick look visible: \(panel?.isVisible ?? false), items: \(panel?.dataSource?.numberOfPreviewItems(in: panel) ?? -1)")
                                print("with quick look open: \(visibleWindows())")
                                // Step Quick Look on, as its arrow keys would; search's highlight should follow.
                                guard let store = controller()?.store, store.searchResults.count > 2 else { exit(0) }
                                panel?.currentPreviewItemIndex = 2
                                after(0.5) {
                                    let followed = store.searchSelection == store.searchResults[2].url
                                    print("highlight followed quick look to item 3: \(followed)")
                                    // Close, then reopen on another shot: it should already hold that
                                    // shot when it appears, not the last one it showed.
                                    panel?.orderOut(nil)
                                    after(0.5) {
                                        let target = store.searchResults[1]
                                        store.quickLook(target, among: store.searchResults, follow: { store.searchSelection = $0 })
                                        let held = AppDelegate.itemWhenShown
                                        print("reopened on item 2; held the right shot as it appeared: \(held == target.url) (was item 3 last time)")
                                        exit(0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Runs the shelf's actions on the sample shots in `--folder` (never your real screenshots) and
    /// prints what happened: links and QR codes found, selecting, pinning, trash and undo, a floating
    /// shot and the markup editor. Moves samples to the Trash and back along the way.
    private static func selfTestActions() {
        guard ShotScanner.testFolder != nil else {
            print("--selftest-actions needs --folder <dir of sample shots>")
            exit(1)
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func exists(_ shot: Shot) -> Bool { FileManager.default.fileExists(atPath: shot.url.path) }
        /// Saves what a window's own views draw into the sample folder's hidden .ShotShelf folder. The
        /// glass is drawn by the window server, so it's missing, and a view with tinted interactive
        /// glass (like the selection bar) comes out blank.
        func snapshot(_ window: NSWindow?, _ name: String) {
            guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = ShotScanner.folder.appendingPathComponent(".ShotShelf/\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        Task { @MainActor in
            await pause(2)
            guard let controller = AppDelegate.shared?.statusController else { exit(1) }
            let store = controller.store
            var waited = 0
            while (store.shots.isEmpty || store.indexing > 0) && waited < 60 {
                await pause(0.5)
                waited += 1
            }
            print("shots: \(store.shots.map(\.url.lastPathComponent))")
            for shot in store.shots {
                print("  quick actions in \(shot.url.lastPathComponent): \(store.links(for: shot).map(\.title))")
            }

            controller.toggle()
            await pause(1)
            snapshot(store.panelWindow, "opened")
            for tab in SettingsTab.allCases {
                store.settingsTab = tab
                store.showSettings = true
                await pause(0.8)
                let popover = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") }
                print("settings \(tab.rawValue): \(popover.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "not open")")
                snapshot(popover, "settings-\(tab.rawValue)")
            }
            store.showSettings = false
            store.settingsTab = .general
            await pause(0.5)
            store.selectAll(Array(store.visible))
            print("selected all: \(store.selection.count), menu acts on \(store.group(for: store.shots[0]).count)")
            store.togglePin(store.selectedShots)
            print("pinned after pin all: \(store.shots.filter(store.isPinned).count)")
            store.togglePin(store.selectedShots)
            print("pinned after pin all again: \(store.shots.filter(store.isPinned).count)")
            store.selection = []

            let victim = store.shots[store.shots.count - 1]
            store.togglePin(victim)
            store.trash([victim])
            await pause(1)
            print("trashed one: file there \(exists(victim)), on shelf \(store.shots.contains(victim)), toast “\(store.toast?.text ?? "-")” undo \(store.toast?.undo ?? false)")
            snapshot(store.panelWindow, "trashed")
            store.undoTrash()
            await pause(1)
            print("after undo: file there \(exists(victim)), on shelf \(store.shots.contains(victim)), still pinned \(store.isPinned(victim)), toast “\(store.toast?.text ?? "-")”")
            store.togglePin(victim)

            let two = Array(store.shots.prefix(2))
            store.trash(two)
            await pause(1)
            print("trashed two: \(two.filter(exists).count) left, toast “\(store.toast?.text ?? "-")”")
            store.undoTrash()
            await pause(1)
            print("after undo: \(two.filter(exists).count) of 2 back")

            let still = store.shots.filter { !$0.isVideo }
            store.float(still[0])
            await pause(1)
            snapshot(store.floaterWindows.first, "floating")
            for window in store.floaterWindows {
                print("floating: \(Int(window.frame.width))×\(Int(window.frame.height)) visible \(window.isVisible) key \(window.isKeyWindow) level \(window.level.rawValue)")
            }
            store.floaterWindows.first?.close()
            await pause(0.5)
            print("floating after close: \(store.floaterWindows.count)")

            store.markup(still[0])
            await pause(1)
            let markup = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Markup") }
            snapshot(markup.first, "markup")
            print("markup editor: \(markup.map { "\($0.title) \(Int($0.frame.width))×\(Int($0.frame.height))" })")
            markup.forEach { $0.close() }
            let sample = { (time: String) -> Shot? in store.shots.first { $0.url.lastPathComponent.contains(time) } }
            let support = ShotScanner.folder.appendingPathComponent(".ShotShelf")

            // Redact Private Info, and a background.
            if let account = sample("08.30.00"), let model = MarkupModel(shot: account) {
                model.redactPrivateInfo()
                await pause(0.5)
                for _ in 0..<160 where model.findingPrivate { await pause(0.25) }
                print("redact private info: \(model.marks.count) redactions, notice “\(model.notice ?? "-")”")
                model.backdrop = .ocean
                try? model.render()?.write(to: support.appendingPathComponent("redacted-framed.png"))
            }

            // Duplicates, combining, the subject.
            print("duplicates: \(store.duplicates.map(\.url.lastPathComponent)), tidy offers \(store.tidyCandidates.count) (\(store.tidyDuplicateCount) as duplicates)")
            if let a = sample("08.40.00"), let b = sample("08.50.00") {
                let before = Set(store.shots.map(\.url))
                store.combine([a, b], stacked: false)
                await pause(2)
                if let made = store.shots.first(where: { !before.contains($0.url) }), let image = ShotTools.cgImage(made.url) {
                    print("combined: \(made.url.lastPathComponent) \(image.width)×\(image.height)")
                    try? FileManager.default.removeItem(at: made.url)
                }
            }
            if let ball = sample("08.55.00"), let text = sample("09.10.00") {
                let lifted = await Task.detached { (ShotTools.subject(ball.url), ShotTools.subject(text.url)) }.value
                print("subject from the ball: \(lifted.0.flatMap { NSImage(data: $0)?.size }.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none"), from text: \(lifted.1 == nil ? "none" : "some")")
            }

            // Translate opens the system popover with the shot's text.
            if let notes = sample("09.00.00") {
                store.translate(notes)
                await pause(1.5)
                print("translate: showing \(store.showTranslation), \(store.translation.split(separator: "\n").count) lines")
                store.showTranslation = false
            }

            // Shortcuts that act on the newest shot.
            let combo = Shortcut(keyCode: UInt32(kVK_F12), modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘F12")
            store.setShortcut(combo, for: .floatNewest)
            print("float newest shortcut registered: \(store.isRegistered(.floatNewest))")
            controller.close()
            store.perform(.floatNewest)
            await pause(1)
            print("floated newest: \(store.floatingShots.map { $0.window.title.isEmpty ? "1 window" : $0.window.title })")
            store.floatingShots.forEach { $0.window.close() }
            store.setShortcut(nil, for: .floatNewest)
            if let notes = sample("09.00.00") {
                store.float(notes)
                await pause(1)
                if let floater = store.floatingShots.first {
                    floater.model.liveText = true
                    await pause(4)
                    print("Live Text: analysed \(floater.model.analysis != nil), found text \(floater.model.analysis?.hasResults(for: .text) ?? false)")
                    snapshot(floater.window, "livetext")
                    floater.window.close()
                }
            }

            // A new screenshot while the shelf is closed brings up the pop-up.
            await pause(0.5)
            if let source = sample("09.10.00") {
                // Written afresh (a copy would keep the old creation date, and only new shots pop up).
                let fresh = ShotScanner.folder.appendingPathComponent("Screenshot 2026-10-22 at 23.59.00.png")
                try? FileManager.default.removeItem(at: fresh)
                try? Data(contentsOf: source.url).write(to: fresh)
                ShotScanner.tagAsScreenshot(fresh)
                await pause(3)
                print("pop-up: \(store.popup?.url.lastPathComponent ?? "none"), window up \(controller.popupVisible), thumbnail \(store.popupImage != nil)")
                snapshot(controller.popupWindow, "popup")
                if let popup = store.popup { try? FileManager.default.removeItem(at: popup.url) }
                store.dismissPopup()
                await pause(0.6)
                print("pop-up after dismiss: window up \(controller.popupVisible)")
            }
            store.showToast("Copied image", symbol: "checkmark.circle.fill")
            await pause(0.6)
            print("notice under the icon with the shelf closed: \(controller.noticeVisible)")

            // Screen recordings.
            if let recording = store.shots.first(where: \.isVideo) {
                await store.refresh()
                print("recording: \(recording.url.lastPathComponent), tile frame \(store.thumbnails[recording.url] != nil), runs \(store.durations[recording.url].map(Recording.label) ?? "?")")
                let gif = support.appendingPathComponent("test.gif"), cut = support.appendingPathComponent("test.mov")
                try? FileManager.default.removeItem(at: gif)
                try? FileManager.default.removeItem(at: cut)
                let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
                try? await Recording.gif(from: recording.url, range: range, width: 320, fps: 10, to: gif) { _ in }
                let frames = CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                try? await Recording.trimmed(from: recording.url, range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), to: cut)
                print("gif: \(frames) frames, trimmed copy runs \(await Recording.duration(cut).map { String(format: "%.1fs", $0) } ?? "none")")
                store.editRecording(recording)
                await pause(1.5)
                let editor = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Recording") }
                print("recording editor: \(editor.map { "\($0.title) \(Int($0.frame.width))×\(Int($0.frame.height))" })")
                snapshot(editor.first, "recording")
                editor.forEach { $0.close() }
            }
            exit(0)
        }
    }
    #endif

    var body: some Scene {
        // The menu bar item and panel are AppKit (see StatusController); SwiftUI just needs a scene.
        Settings { EmptyView() }
    }
}
