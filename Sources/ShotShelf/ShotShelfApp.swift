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
    }

    @MainActor private static func renderPanel(to path: String) {
        let store = ShelfStore(preview: ShotScanner.scan(ShotScanner.folder) ?? [])
        store.hovered = store.shots.first?.url  // show the hover actions on one cell
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--size"), i + 1 < args.count, let size = PanelSize(rawValue: args[i + 1].capitalized) {
            store.panelSize = size
        }
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
                controller()?.close()
                controller()?.store.openSearch()
                after(1.5) {
                    print("after search shortcut: \(visibleWindows())")
                    controller()?.close()
                    let urls = (ShotScanner.scan(ShotScanner.folder) ?? []).map(\.url)
                    AppDelegate.toggleQuickLook(urls, at: 0)
                    after(1.5) {
                        let panel = QLPreviewPanel.shared()
                        print("quick look visible: \(panel?.isVisible ?? false), items: \(panel?.dataSource?.numberOfPreviewItems(in: panel) ?? -1)")
                        exit(0)
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
