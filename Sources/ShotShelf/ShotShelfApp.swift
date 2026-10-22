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
    static let smartNames = "smartNames"      // Bool, rename new shots from their text
    static let mascot = "mascot"              // Bool, mascot snaps a photo for new shots
}

@main
struct ShotShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Debug flags: `--dump` lists the screenshots found, `--render <file.png> [--size small|medium|large]` saves the panel,
        // `--selftest` opens the panel and Quick Look on screen and reports what happened.
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
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-icons"), i + 1 < args.count {
            Self.renderIcons(to: args[i + 1])
            exit(0)
        }
        if args.contains("--selftest") { Self.selfTest() }

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

    @MainActor private static func renderPanel(to path: String) {
        let store = ShelfStore(preview: ShotScanner.scan(ShotScanner.folder) ?? [])
        store.hovered = store.shots.first?.url  // show the hover actions on one cell
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--size"), i + 1 < args.count, let size = PanelSize(rawValue: args[i + 1].capitalized) {
            store.panelSize = size
        }
        if args.contains("--extras") { store.addPreviewExtras() }
        let renderer = ImageRenderer(content: ShelfView(store: store)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Every menu bar icon frame side by side, big, on a dark and a light strip.
    @MainActor private static func renderIcons(to path: String) {
        let frames: [ShelfIcon.Frame] = [.polaroid, .mascot, .holding, .flash]
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            ForEach([Color.black, Color(white: 0.92)], id: \.self) { bg in
                HStack(spacing: 24) {
                    ForEach(frames, id: \.self) { frame in
                        Image(nsImage: ShelfIcon.image(size: 72, frame: frame)).renderingMode(frame == .polaroid ? .template : .original)
                            .foregroundStyle(bg == .black ? .white : .black)
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
                                store.quickLook(first, among: store.searchResults)
                            }
                            after(1.5) {
                                let panel = QLPreviewPanel.shared()
                                print("quick look visible: \(panel?.isVisible ?? false), items: \(panel?.dataSource?.numberOfPreviewItems(in: panel) ?? -1)")
                                print("with quick look open: \(visibleWindows())")
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
    }

    var body: some Scene {
        // The menu bar item and panel are AppKit (see StatusController); SwiftUI just needs a scene.
        Settings { EmptyView() }
    }
}
