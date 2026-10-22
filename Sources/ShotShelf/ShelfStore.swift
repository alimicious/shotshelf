import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum UpdateStatus: Equatable {
    case idle, checking, upToDate, downloading, installing
    case failed(String)
}

/// The two global shortcuts you can set.
enum ShortcutSlot {
    case open, search
}

struct Toast: Equatable {
    let text: String
    let symbol: String
    /// Shows an Undo button, for putting back what was just moved to the Trash.
    var undo = false
    let id = UUID()
}

/// Shots just moved to the Trash, so Undo can put them back where they were.
private struct Trashed {
    let original: URL
    let inTrash: URL
    let wasPinned: Bool
}

@MainActor
final class ShelfStore: ObservableObject {
    /// In display order: the first one gets the big slot.
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    /// Smaller thumbnails for the Show All grid, loaded as its cells appear.
    @Published private(set) var minis: [URL: NSImage] = [:]
    @Published private(set) var pinned: Set<String>
    /// Folders shown as chips under the grid; dropping a shot on one moves it there.
    @Published private(set) var folders: [URL]
    /// The text read from each shot, by path. Powers Copy Text, search and smart names.
    @Published private(set) var texts: [String: String] {
        didSet { linkCache = [:] }
    }
    /// What the QR codes in each shot say, by path.
    @Published private(set) var codes: [String: [String]] {
        didSet { linkCache = [:] }
    }
    /// How many shots are still waiting to have their text read.
    @Published private(set) var indexing = 0
    @Published private(set) var folderReadable = true
    /// Shots taken since the panel was last opened: the menu bar badge.
    @Published private(set) var newCount = 0
    /// Shots newer than this get a dot while the panel is open.
    @Published private(set) var freshSince = Date()
    @Published private(set) var toast: Toast?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// The hovered shot, which arrow keys also move, so it doubles as the keyboard selection.
    @Published var hovered: URL?
    /// Shots picked with ⌘-click or ⇧-click (or ⌘A), which the footer's actions and keys then act on
    /// together. Shared by the shelf and search.
    @Published var selection: Set<URL> = []
    /// The shot being dragged and what it's over, while rearranging or filing.
    @Published var dragging: URL?
    /// True while the whole selection is being dragged, from the footer's stack.
    @Published var draggingSelection = false
    @Published var dropTarget: URL?
    @Published var dropFolder: URL?
    @Published var confirmingTidy = false
    @Published var showSettings = false {
        didSet { if !showSettings { cancelRecording() } }
    }
    /// Small, medium or large: bigger panels show bigger tiles and more of them.
    @Published var panelSize: PanelSize {
        didSet {
            UserDefaults.standard.set(panelSize.rawValue, forKey: Prefs.panelSize)
            Task { await loadThumbnails() }
        }
    }
    @Published private(set) var openShortcut: Shortcut?
    @Published private(set) var searchShortcut: Shortcut?
    /// Which shortcut is waiting for you to press keys, if any.
    @Published private(set) var recording: ShortcutSlot?
    /// A newer signed release on GitHub, once a check has found one.
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var updateStatus: UpdateStatus = .idle
    @Published var showUpdate = false
    @Published var showAll = false {
        didSet { if showAll && !oldValue { searchFocused = true } }
    }
    @Published var query = ""
    /// The selected shot in search, moved by the arrow keys and the pointer.
    @Published var searchSelection: URL?
    /// Whether typing goes to the search field (true) or the arrow keys drive the results (false).
    @Published var searchFocused = true
    /// Up to 20 capture sizes, shown in the capture bar under the shelf.
    @Published private(set) var presets: [CapturePreset]
    /// The add/edit form for a preset, while it's open.
    @Published var presetEditor: PresetDraft?
    @Published var hoveredPreset: UUID?
    /// The first-launch card. Nothing is read from the screenshot folder until it's dismissed, so
    /// macOS asks for access only after the card has said why.
    @Published private(set) var showWelcome = false

    let folder = ShotScanner.folder
    let iconAnimator = IconAnimator()
    /// True for the static store `--render` draws; it never touches files or the menu bar.
    let isPreview: Bool
    /// The panel's window, so keyboard shortcuts only act while it's the one in front.
    weak var panelWindow: NSWindow?
    /// The search panel beside it, which gets its own keys.
    weak var searchWindow: NSWindow?
    /// Set by the status item, which owns the panel.
    var togglePanel: (() -> Void)?
    var closePanel: (() -> Void)?

    private var watcher: FolderWatcher?
    private var captureOverlay: CaptureOverlay?
    private var openHotKey: HotKey?
    private var searchHotKey: HotKey?
    private var markupWindow: NSWindow?
    private var floaters: [FloatingShot] = []
    /// What the last Trash or Tidy moved, until it's undone or something else is trashed.
    private var lastTrashed: [Trashed] = []
    /// Where the last ⌘- or ⇧-click landed, so the next ⇧-click selects the range from it.
    private var selectionAnchor: URL?
    private var linkCache: [String: [ShotLink]] = [:]
    private var knownPaths: Set<String>?
    /// Paths already treated as new arrivals, including the names they were renamed to.
    private var handled: Set<String> = []
    /// Paths whose text is being read right now, so indexing doesn't read them twice.
    private var reading: Set<String> = []
    private var loadingMinis: Set<URL> = []
    private var isIndexing = false

    /// A static store for rendering the panel without a menu bar (see `--render`).
    init(preview shots: [Shot]) {
        isPreview = true
        panelSize = Self.loadPanelSize()
        pinned = Self.loadPinned()
        folders = Self.loadFolders()
        texts = Self.loadTexts()
        codes = Self.loadCodes()
        presets = Self.loadPresets()
        self.shots = Self.arranged(shots)
        freshSince = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Prefs.lastSeen))
        for shot in self.shots.prefix(panelSize.slots) { thumbnails[shot.url] = ShotScanner.thumbnail(shot.url) }
    }

    init() {
        isPreview = false
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Prefs.smartNames: true,
            Prefs.iconAnimation: true,
            Prefs.autoUpdates: true,
            Prefs.searchEyes: true,
        ])
        panelSize = Self.loadPanelSize()
        openShortcut = Self.loadShortcut(Prefs.openShortcut, fallback: Shortcut.legacy(defaults.string(forKey: Prefs.hotKey)) ?? .openDefault)
        searchShortcut = Self.loadShortcut(Prefs.searchShortcut, fallback: nil)
        pinned = Self.loadPinned()
        folders = Self.loadFolders()
        texts = Self.loadTexts()
        codes = Self.loadCodes()
        presets = Self.loadPresets()
        // People updating from before the welcome card have used the app already, so skip it for them.
        if defaults.object(forKey: Prefs.welcomed) == nil {
            defaults.set(defaults.double(forKey: Prefs.lastSeen) != 0, forKey: Prefs.welcomed)
        }
        showWelcome = !defaults.bool(forKey: Prefs.welcomed) && ShotScanner.testFolder == nil
        applyHotKeys()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if let slot = self.recording {
                    self.record(event, for: slot)
                    return true
                }
                // Leave typing in text fields (like search) alone.
                if event.window === self.searchWindow { return self.handleSearchKey(event) }
                guard event.window === self.panelWindow, !(event.window?.firstResponder is NSText) else { return false }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
        if !showWelcome { start() }
    }

    /// Starts watching and reading the screenshot folder, which is when macOS asks for access to it.
    private func start() {
        let defaults = UserDefaults.standard
        // On first launch, count only shots taken from now on as new.
        if defaults.double(forKey: Prefs.lastSeen) == 0 { defaults.set(Date().timeIntervalSince1970, forKey: Prefs.lastSeen) }
        watcher = FolderWatcher(folder) { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        Task {
            while !Task.isCancelled {
                await refresh()
                autoTidy()
                await checkForUpdatesIfDue()
                // The watcher catches new shots instantly; this just picks up auto-tidy and missed events.
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func finishWelcome() {
        guard showWelcome else { return }
        showWelcome = false
        UserDefaults.standard.set(true, forKey: Prefs.welcomed)
        start()
    }

    var visible: ArraySlice<Shot> { shots.prefix(panelSize.slots) }
    var todayCount: Int { shots.filter { Calendar.current.isDateInToday($0.date) }.count }

    /// Shots whose name or text matches the search, in shelf order.
    var searchResults: [Shot] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return shots }
        return shots.filter {
            $0.url.deletingPathExtension().lastPathComponent.localizedStandardContains(q)
                || texts[$0.url.path]?.localizedStandardContains(q) == true
        }
    }

    func isPinned(_ shot: Shot) -> Bool { pinned.contains(shot.url.path) }

    // MARK: - Loading

    func refresh() async {
        let folder = folder
        let scanned = await Task.detached { ShotScanner.scan(folder) }.value
        folderReadable = scanned != nil
        shots = Self.arranged(scanned ?? [])
        let lastSeen = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Prefs.lastSeen))
        newCount = shots.filter { $0.date > lastSeen }.count
        let live = Set(shots.map(\.url))
        minis = minis.filter { live.contains($0.key) }
        selection = selection.filter(live.contains)
        detectArrivals()
        indexText()
        await loadThumbnails()
    }

    private func folderChanged() {
        Task {
            await refresh()
            // The screenshot tag can land a moment after the file appears, so look again shortly.
            try? await Task.sleep(for: .seconds(1.5))
            await refresh()
        }
    }

    private func loadThumbnails() async {
        let wanted = Set(visible.map(\.url))
        thumbnails = thumbnails.filter { wanted.contains($0.key) }
        for url in wanted where thumbnails[url] == nil {
            thumbnails[url] = await Task.detached { ShotScanner.thumbnail(url) }.value
        }
    }

    func requestMini(_ url: URL) {
        guard minis[url] == nil, !loadingMinis.contains(url) else { return }
        loadingMinis.insert(url)
        Task {
            minis[url] = await Task.detached(priority: .utility) { ShotScanner.thumbnail(url, maxPixels: 300) }.value
            loadingMinis.remove(url)
        }
    }

    /// Puts shots in the order you arranged them. Ones you haven't placed yet (new screenshots) go
    /// first, newest first, so the latest shot always lands in the big slot.
    private static func arranged(_ scanned: [Shot]) -> [Shot] {
        let order = UserDefaults.standard.stringArray(forKey: Prefs.order) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let unplaced = scanned.filter { rank[$0.url.path] == nil }
        let placed = scanned.compactMap { s in rank[s.url.path].map { (s, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        return unplaced + placed
    }

    /// Drops `url` into `target`'s spot; the shots in between shift over by one.
    func move(_ url: URL, onto target: URL) {
        guard url != target,
              let from = shots.firstIndex(where: { $0.url == url }),
              let to = shots.firstIndex(where: { $0.url == target }) else { return }
        shots.insert(shots.remove(at: from), at: to)
        UserDefaults.standard.set(shots.map(\.url.path), forKey: Prefs.order)
    }

    func panelOpened() {
        let defaults = UserDefaults.standard
        freshSince = Date(timeIntervalSince1970: defaults.double(forKey: Prefs.lastSeen))
        defaults.set(Date().timeIntervalSince1970, forKey: Prefs.lastSeen)
        newCount = 0
        confirmingTidy = false
        dragging = nil
    }

    // MARK: - New arrivals

    /// Shots that just appeared: the menu bar icon plays its animation, and each one's text is read and
    /// (if smart names are on) used to rename it.
    private func detectArrivals() {
        let paths = Set(shots.map(\.url.path))
        defer { knownPaths = paths }
        guard let known = knownPaths else { return }
        let arrived = shots.filter {
            !known.contains($0.url.path) && !handled.contains($0.url.path) && Date().timeIntervalSince($0.date) < 120
        }
        guard !arrived.isEmpty else { return }
        handled.formUnion(arrived.map(\.url.path))
        if UserDefaults.standard.bool(forKey: Prefs.iconAnimation) { iconAnimator.play() }
        let app = Self.frontmostAppName()
        for shot in arrived {
            Task { await read(shot, namingAfter: app) }
        }
    }

    /// The app you were in when you took the shot, for its smart name.
    private static func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier?.hasPrefix("com.apple.screencapture") != true else { return nil }
        return app.localizedName
    }

    private func read(_ shot: Shot, namingAfter app: String?) async {
        let url = shot.url
        reading.insert(url.path)
        let (lines, found) = await Task.detached { (ShotText.recognize(url), ShotText.codes(url)) }.value
        reading.remove(url.path)
        texts[url.path] = lines.map(\.text).joined(separator: "\n")
        codes[url.path] = found
        saveTexts()
        guard UserDefaults.standard.bool(forKey: Prefs.smartNames),
              let name = ShotText.smartName(lines, app: app, date: shot.date) else { return }
        rename(shot, to: name)
    }

    /// Reads the text and codes of any shot that doesn't have them yet, one at a time in the
    /// background. Shots read before codes were looked for only get the (quick) code check.
    private func indexText() {
        guard !isIndexing, !isPreview else { return }
        let missing = shots.filter {
            (texts[$0.url.path] == nil || codes[$0.url.path] == nil) && !reading.contains($0.url.path)
        }
        guard !missing.isEmpty else { return }
        isIndexing = true
        indexing = missing.count
        Task {
            for shot in missing {
                let url = shot.url
                let needsText = texts[url.path] == nil
                let (text, found) = await Task.detached(priority: .utility) {
                    (needsText ? ShotText.recognize(url).map(\.text).joined(separator: "\n") : nil, ShotText.codes(url))
                }.value
                if FileManager.default.fileExists(atPath: url.path) {
                    if let text { texts[url.path] = text }
                    codes[url.path] = found
                }
                indexing -= 1
            }
            let live = Set(shots.map(\.url.path))
            texts = texts.filter { live.contains($0.key) }
            codes = codes.filter { live.contains($0.key) }
            saveTexts()
            isIndexing = false
            indexing = 0
        }
    }

    // MARK: - Actions

    func copy(_ shot: Shot) {
        let item = NSPasteboardItem()
        // The image itself so it pastes anywhere, plus the file for apps that prefer attachments.
        if let data = try? Data(contentsOf: shot.url) {
            let isPNG = UTType(filenameExtension: shot.url.pathExtension)?.conforms(to: .png) == true
            if isPNG {
                item.setData(data, forType: .png)
            } else if let tiff = NSImage(data: data)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        item.setString(shot.url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        showToast("Copied image", symbol: "checkmark.circle.fill")
    }

    /// Several shots go on the clipboard as files: attachments in chat and mail, copies in Finder.
    func copy(_ shots: [Shot]) {
        guard shots.count > 1 else {
            if let shot = shots.first { copy(shot) }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(shots.map { $0.url as NSURL })
        showToast("Copied \(shots.count) images", symbol: "checkmark.circle.fill")
    }

    /// The macOS share menu (AirDrop, Messages, Mail and so on) for `shots`, at the pointer.
    func share(_ shots: [Shot]) {
        guard !shots.isEmpty, let window = NSApp.keyWindow ?? panelWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: shots.map(\.url))
            .show(relativeTo: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), of: view, preferredEdge: .minY)
    }

    /// Links, email addresses and QR codes found in a shot, for its quick actions.
    func links(for shot: Shot) -> [ShotLink] {
        let path = shot.url.path
        if let cached = linkCache[path] { return cached }
        let found = ShotText.links(text: texts[path] ?? "", codes: codes[path] ?? [])
        linkCache[path] = found
        return found
    }

    /// Opens a web link (from the text or a QR code), or copies an email address or a code's text.
    func use(_ link: ShotLink) {
        if let url = link.url {
            closePanel?()
            NSWorkspace.shared.open(url)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.value, forType: .string)
            showToast(link.kind == .email ? "Copied email address" : "Copied the code's text", symbol: link.symbol)
        }
    }

    func copyText(_ shot: Shot) {
        Task {
            let url = shot.url
            var text = texts[url.path]
            if text == nil {
                text = await Task.detached { ShotText.recognize(url).map(\.text).joined(separator: "\n") }.value
                texts[url.path] = text
                saveTexts()
            }
            guard let text, !text.isEmpty else {
                showToast("No text found", symbol: "text.badge.xmark")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let lines = text.split(separator: "\n").count
            showToast("Copied \(lines) line\(lines == 1 ? "" : "s") of text", symbol: "text.viewfinder")
        }
    }

    /// Previews `shot`. The arrow keys in Quick Look then step through `list` (the whole shelf by
    /// default), and `follow` moves the highlight along with them (the shelf's, by default).
    func quickLook(_ shot: Shot, among list: [Shot]? = nil, follow: ((URL) -> Void)? = nil) {
        let list = list ?? shots
        AppDelegate.toggleQuickLook(list.map(\.url), at: list.firstIndex(of: shot) ?? 0,
                                    follow: follow ?? { [weak self] in self?.hovered = $0 })
    }

    func reveal(_ shot: Shot) {
        NSWorkspace.shared.activateFileViewerSelecting([shot.url])
    }

    func open(_ shot: Shot) {
        NSWorkspace.shared.open(shot.url)
    }

    func togglePin(_ shot: Shot) {
        if pinned.remove(shot.url.path) == nil { pinned.insert(shot.url.path) }
        savePinned()
    }

    /// Pins them all, or unpins them all if they're all pinned already.
    func togglePin(_ shots: [Shot]) {
        let pin = !shots.allSatisfy(isPinned)
        for shot in shots {
            if pin { pinned.insert(shot.url.path) } else { pinned.remove(shot.url.path) }
        }
        savePinned()
    }

    func trash(_ shot: Shot) {
        trash([shot])
    }

    /// Moves shots to the Trash, with Undo in the toast (and ⌘Z) to put them back.
    func trash(_ shots: [Shot]) {
        let moved = moveToTrash(shots)
        guard !moved.isEmpty else { return }
        lastTrashed = moved
        selection.subtract(moved.map(\.original))
        showToast(moved.count == 1 ? "Moved to the Trash" : "Moved \(moved.count) to the Trash", symbol: "trash", undo: true)
    }

    var canUndoTrash: Bool { !lastTrashed.isEmpty }

    /// Puts back what the last Trash or Tidy moved, with their pins and their spots on the shelf.
    func undoTrash() {
        guard !lastTrashed.isEmpty else { return }
        var restored = 0
        for item in lastTrashed where FileManager.default.fileExists(atPath: item.inTrash.path) {
            // If its old name has been taken since, it comes back as "name 2".
            let original = item.original
            let dest = FileManager.default.fileExists(atPath: original.path)
                ? ShotScanner.uniqueURL(in: original.deletingLastPathComponent(),
                                        name: original.deletingPathExtension().lastPathComponent, ext: original.pathExtension)
                : original
            guard (try? FileManager.default.moveItem(at: item.inTrash, to: dest)) != nil else { continue }
            handled.insert(dest.path)  // so it doesn't count as a new screenshot
            if item.wasPinned { pinned.insert(dest.path) }
            restored += 1
        }
        lastTrashed = []
        savePinned()
        switch restored {
        case 0: showToast("Nothing left to put back", symbol: "exclamationmark.triangle")
        case 1: showToast("Put back from the Trash", symbol: "arrow.uturn.backward")
        default: showToast("Put back \(restored) from the Trash", symbol: "arrow.uturn.backward")
        }
        Task { await refresh() }
    }

    func smartRename(_ shot: Shot) {
        Task {
            let url = shot.url
            let lines = await Task.detached { ShotText.recognize(url) }.value
            guard let name = ShotText.smartName(lines, app: nil, date: shot.date) else {
                showToast("No text to name it from", symbol: "text.badge.xmark")
                return
            }
            rename(shot, to: name)
            showToast("Renamed to “\(name)”", symbol: "character.cursor.ibeam")
        }
    }

    /// Renames the file in place, carrying its pin, text and spot on the shelf over to the new name.
    private func rename(_ shot: Shot, to name: String) {
        let dest = ShotScanner.uniqueURL(in: shot.url.deletingLastPathComponent(), name: name, ext: shot.url.pathExtension)
        guard (try? FileManager.default.moveItem(at: shot.url, to: dest)) != nil else { return }
        let old = shot.url.path, new = dest.path
        handled.insert(new)
        if pinned.remove(old) != nil {
            pinned.insert(new)
            savePinned()
        }
        texts[new] = texts.removeValue(forKey: old)
        codes[new] = codes.removeValue(forKey: old)
        saveTexts()
        var order = UserDefaults.standard.stringArray(forKey: Prefs.order) ?? []
        if let i = order.firstIndex(of: old) {
            order[i] = new
            UserDefaults.standard.set(order, forKey: Prefs.order)
        }
        if hovered == shot.url { hovered = dest }
        if selection.remove(shot.url) != nil { selection.insert(dest) }
        Task { await refresh() }
    }

    // MARK: - Markup

    /// Opens the markup editor: arrows, boxes, highlights, text and pixelated redactions, saved as a copy.
    func markup(_ shot: Shot) {
        guard let model = MarkupModel(shot: shot) else {
            showToast("Couldn't open that shot", symbol: "exclamationmark.triangle")
            return
        }
        markupWindow?.close()
        closePanel?()
        let view = MarkupView(
            model: model,
            onCopy: { [weak self] data in
                self?.copyImageData(data, redactedOnly: model.redactsOnly)
                self?.markupWindow?.close()
            },
            onSave: { [weak self] data in
                self?.saveMarkedUp(data, from: shot, redactedOnly: model.redactsOnly)
                self?.markupWindow?.close()
            })

        // Fit the shot in at most 960×640, plus room for the padding and toolbar.
        let width = min(960, 640 * model.aspect)
        let size = NSSize(width: max(640, width + 32), height: max(420, width / model.aspect + 32 + 56))
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Markup – \(shot.url.deletingPathExtension().lastPathComponent)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        markupWindow = window
    }

    private func copyImageData(_ data: Data, redactedOnly: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        showToast(redactedOnly ? "Copied redacted image" : "Copied marked-up image",
                  symbol: redactedOnly ? "eye.slash" : "pencil.tip.crop.circle")
    }

    /// Saves next to the original as "… (marked up).png", or "… (redacted).png" when all it has is
    /// redactions, tagged as a screenshot so it lands on the shelf.
    private func saveMarkedUp(_ data: Data, from shot: Shot, redactedOnly: Bool) {
        let name = shot.url.deletingPathExtension().lastPathComponent + (redactedOnly ? " (redacted)" : " (marked up)")
        let dest = ShotScanner.uniqueURL(in: shot.url.deletingLastPathComponent(), name: name, ext: "png")
        handled.insert(dest.path)
        do {
            try data.write(to: dest)
            ShotScanner.tagAsScreenshot(dest)
            showToast(redactedOnly ? "Saved a redacted copy" : "Saved a marked-up copy",
                      symbol: redactedOnly ? "eye.slash" : "pencil.tip.crop.circle")
        } catch {
            showToast("Couldn't save the copy", symbol: "exclamationmark.triangle")
        }
        Task { await refresh() }
    }

    // MARK: - Folders

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to file screenshots into"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        folders.append(contentsOf: panel.urls.filter { !folders.contains($0) })
        saveFolders()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        saveFolders()
    }

    func file(_ shot: Shot, into folder: URL) {
        file([shot], into: folder)
    }

    /// Moves shots into one of the folders, which takes them off the shelf.
    func file(_ shots: [Shot], into folder: URL) {
        var moved = 0
        for shot in shots {
            let name = shot.url.deletingPathExtension().lastPathComponent
            let dest = ShotScanner.uniqueURL(in: folder, name: name, ext: shot.url.pathExtension)
            guard (try? FileManager.default.moveItem(at: shot.url, to: dest)) != nil else { continue }
            pinned.remove(shot.url.path)
            texts[shot.url.path] = nil
            codes[shot.url.path] = nil
            selection.remove(shot.url)
            moved += 1
        }
        savePinned()
        switch moved {
        case 0: showToast("Couldn't move \(shots.count == 1 ? "it" : "them") to \(folder.lastPathComponent)", symbol: "exclamationmark.triangle")
        case 1: showToast("Moved to \(folder.lastPathComponent)", symbol: "folder.fill")
        default: showToast("Moved \(moved) to \(folder.lastPathComponent)", symbol: "folder.fill")
        }
        Task { await refresh() }
    }

    // MARK: - Tidy

    /// Unpinned shots from before today: what the Tidy button sends to the Trash.
    var tidyCandidates: [Shot] {
        let today = Calendar.current.startOfDay(for: Date())
        return shots.filter { $0.date < today && !isPinned($0) }
    }

    func tidy() {
        trash(tidyCandidates)
        confirmingTidy = false
    }

    private func autoTidy() {
        let days = UserDefaults.standard.integer(forKey: Prefs.autoTidyDays)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        moveToTrash(shots.filter { $0.date < cutoff && !isPinned($0) })
    }

    /// Moves files to the Trash (never deletes them outright), so anything tidied can be put back,
    /// and returns where each one went.
    @discardableResult
    private func moveToTrash(_ victims: [Shot]) -> [Trashed] {
        guard !victims.isEmpty else { return [] }
        var moved: [Trashed] = []
        for shot in victims {
            var inTrash: NSURL?
            guard (try? FileManager.default.trashItem(at: shot.url, resultingItemURL: &inTrash)) != nil,
                  let inTrash else { continue }
            let wasPinned = pinned.remove(shot.url.path) != nil
            moved.append(Trashed(original: shot.url, inTrash: inTrash as URL, wasPinned: wasPinned))
        }
        savePinned()
        Task { await refresh() }
        return moved
    }

    // MARK: - Selection

    /// The selected shots, in shelf order.
    var selectedShots: [Shot] { shots.filter { selection.contains($0.url) } }

    /// What a menu opened on `shot` acts on: the whole selection when `shot` is part of it.
    func group(for shot: Shot) -> [Shot] {
        selection.count > 1 && selection.contains(shot.url) ? selectedShots : [shot]
    }

    /// A click on a shot in `list`: ⌘ adds or removes it, ⇧ adds the run from the last one clicked,
    /// and a plain click clears the selection.
    func click(_ shot: Shot, in list: [Shot]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let anchor = selectionAnchor,
           let a = list.firstIndex(where: { $0.url == anchor }), let b = list.firstIndex(of: shot) {
            selection.formUnion(list[min(a, b)...max(a, b)].map(\.url))
        } else if mods.contains(.command) || mods.contains(.shift) {
            if selection.remove(shot.url) == nil { selection.insert(shot.url) }
            selectionAnchor = shot.url
        } else {
            if !selection.isEmpty { selection = [] }
            selectionAnchor = shot.url
        }
    }

    func selectAll(_ list: [Shot]) {
        selection = Set(list.map(\.url))
    }

    /// Keys for the whole selection: Space previews it, Delete trashes it, ⌘C copies it, P pins it.
    private func actOnSelection(_ event: NSEvent) -> Bool {
        let group = selectedShots
        guard !group.isEmpty else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, mods, key) {
        case (49, [], _): AppDelegate.toggleQuickLook(group.map(\.url), at: 0)
        case (51, [], _), (51, .command, _), (117, [], _): trash(group)
        case (_, .command, "c"): copy(group)
        case (_, [], "p"): togglePin(group)
        default: return false
        }
        return true
    }

    // MARK: - Floating

    /// Keeps a shot on screen above other windows, to refer to while you work.
    func float(_ shot: Shot) {
        guard let floater = FloatingShot(shot: shot, cascade: floaters.count,
                                         onCopy: { [weak self] in self?.copy(shot) },
                                         onClose: { [weak self] closed in self?.floaters.removeAll { $0 === closed } })
        else {
            showToast("Couldn't open that shot", symbol: "exclamationmark.triangle")
            return
        }
        floaters.append(floater)
        closePanel?()
        floater.show()
    }

    /// For `--selftest-actions`: the floating shots' windows.
    var floaterWindows: [NSWindow] { floaters.map(\.window) }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let shots = Array(visible)
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 {  // Escape: clear the selection first, then close
            if !selection.isEmpty { selection = [] } else { closePanel?() }
            return true
        }
        if key == "f", mods == .command {
            showAll = true
            return true
        }
        if key == "z", mods == .command, canUndoTrash {
            undoTrash()
            return true
        }
        if key == "a", mods == .command {
            selectAll(shots)
            return true
        }
        guard !shots.isEmpty else { return false }
        if actOnSelection(event) { return true }
        let index = hovered.flatMap { url in shots.firstIndex { $0.url == url } }
        if let next = Self.neighbour(of: index, keyCode: event.keyCode, count: shots.count, columns: panelSize.columns) {
            hovered = shots[next].url
            return true
        }
        // Space with nothing selected previews the newest shot.
        guard let shot = index.map({ shots[$0] }) ?? (event.keyCode == 49 ? shots.first : nil) else { return false }
        return act(on: shot, in: self.shots, event: event) { self.hovered = $0 }
    }

    /// Keys for the search panel. In the search field everything is typing, except Down or Return,
    /// which move into the results. There, arrows move, Up from the top row goes back to the
    /// field, the shot keys work as on the shelf, and typing a letter carries on the search.
    private func handleSearchKey(_ event: NSEvent) -> Bool {
        let results = searchResults
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let index = searchSelection.flatMap { url in results.firstIndex { $0.url == url } }
        let inField = event.window?.firstResponder is NSText

        if event.keyCode == 53 {  // Escape: clear the search first, then the selection, then close
            if inField, !query.isEmpty { query = "" } else if !selection.isEmpty { selection = [] } else { showAll = false }
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "f", mods == .command {
            searchFocused = true
            return true
        }
        if inField {
            guard [125, 36].contains(event.keyCode), !results.isEmpty else { return false }
            searchSelection = results[index ?? 0].url
            searchFocused = false
            return true
        }
        // ⌘Z and ⌘A stay with the text while typing in the field.
        if event.charactersIgnoringModifiers?.lowercased() == "z", mods == .command, canUndoTrash {
            undoTrash()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "a", mods == .command {
            selectAll(results)
            return true
        }
        guard !results.isEmpty else { return false }
        let columns = 3
        switch event.keyCode {
        case 123, 124, 125, 126:
            guard let i = index else {
                searchSelection = results[0].url
                return true
            }
            let last = results.count - 1
            switch event.keyCode {
            case 123: searchSelection = results[max(i - 1, 0)].url
            case 124: searchSelection = results[min(i + 1, last)].url
            case 125 where i / columns < last / columns: searchSelection = results[min(i + columns, last)].url
            case 126 where i < columns: searchFocused = true
            case 126: searchSelection = results[i - columns].url
            default: break
            }
            return true
        default:
            if actOnSelection(event) { return true }
            if let shot = index.map({ results[$0] }) ?? (event.keyCode == 49 ? results.first : nil),
               act(on: shot, in: results, event: event, select: { self.searchSelection = $0 }) {
                return true
            }
            // Anything else typed goes back into the search.
            if mods.isDisjoint(with: [.command, .control]), let typed = event.characters,
               !typed.isEmpty, !typed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                query += typed
                searchFocused = true
                return true
            }
            return false
        }
    }

    /// The keys that act on one shot, shared by the shelf and search: Space previews (stepping
    /// through `list`), Return opens, Delete trashes, ⌘C copies, T copies text, P pins, R marks up
    /// and F floats it on screen.
    private func act(on shot: Shot, in list: [Shot], event: NSEvent, select: @escaping (URL?) -> Void) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, mods, key) {
        case (49, [], _): quickLook(shot, among: list, follow: { select($0) })  // Space
        case (36, [], _): open(shot)                                       // Return
        case (51, [], _), (51, .command, _), (117, [], _):                 // Delete
            // Keep a selection so you can tap through and trash several in a row.
            let rest = list.filter { $0 != shot }
            let i = list.firstIndex(of: shot) ?? 0
            select(rest.indices.contains(i) ? rest[i].url : rest.last?.url)
            trash(shot)
        case (_, .command, "c"): copy(shot)
        case (_, [.command, .shift], "c"), (_, [], "t"): copyText(shot)
        case (_, [], "p"): togglePin(shot)
        case (_, [], "r"): markup(shot)
        case (_, [], "f"): float(shot)
        default: return false
        }
        return true
    }

    /// Arrow-key moves around the shelf: the big slot on top, then rows of `columns` tiles.
    private static func neighbour(of index: Int?, keyCode: UInt16, count: Int, columns: Int) -> Int? {
        guard [123, 124, 125, 126].contains(keyCode) else { return nil }
        guard let i = index else { return 0 }
        let target: Int
        switch keyCode {
        case 123: target = i - 1                                  // left
        case 124: target = i + 1                                  // right
        case 125: target = i == 0 ? 1 : i + columns               // down
        default: target = i <= columns ? 0 : i - columns          // up
        }
        return (0..<count).contains(target) ? target : i
    }

    // MARK: - Settings

    var hotKeyRegistered: Bool { openHotKey != nil }

    func shortcut(for slot: ShortcutSlot) -> Shortcut? {
        slot == .open ? openShortcut : searchShortcut
    }

    private func applyHotKeys() {
        openHotKey = nil
        searchHotKey = nil
        openHotKey = openShortcut.flatMap { HotKey($0) { [weak self] in MainActor.assumeIsolated { self?.togglePanel?() } } }
        searchHotKey = searchShortcut.flatMap { HotKey($0) { [weak self] in MainActor.assumeIsolated { self?.openSearch() } } }
    }

    /// Opens the shelf straight into search with the field ready; pressing it again closes both.
    func openSearch() {
        if panelWindow?.isVisible == true, showAll {
            closePanel?()
        } else {
            showAll = true
        }
    }

    func startRecording(_ slot: ShortcutSlot) {
        recording = slot
        // Let the current shortcuts through as ordinary key presses so they can be re-recorded.
        openHotKey = nil
        searchHotKey = nil
    }

    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil
        applyHotKeys()
    }

    /// Esc cancels, Delete clears, and anything with ⌘, ⌥ or ⌃ becomes the new shortcut.
    private func record(_ event: NSEvent, for slot: ShortcutSlot) {
        switch Int(event.keyCode) {
        case 53:
            cancelRecording()
        case 51, 117:
            recording = nil
            setShortcut(nil, for: slot)
        default:
            guard let shortcut = Shortcut(event: event) else {
                NSSound.beep()  // needs ⌘, ⌥ or ⌃; keep listening
                return
            }
            recording = nil
            let other: ShortcutSlot = slot == .open ? .search : .open
            if self.shortcut(for: other) == shortcut {
                showToast("\(shortcut.display) is already in use", symbol: "exclamationmark.triangle")
                applyHotKeys()
                return
            }
            setShortcut(shortcut, for: slot)
        }
    }

    func setShortcut(_ shortcut: Shortcut?, for slot: ShortcutSlot) {
        switch slot {
        case .open: openShortcut = shortcut
        case .search: searchShortcut = shortcut
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: slot == .open ? Prefs.openShortcut : Prefs.searchShortcut)
        applyHotKeys()
        if let shortcut, shortcutHotKey(slot) == nil {
            showToast("\(shortcut.display) is taken by another app", symbol: "exclamationmark.triangle")
        }
    }

    private func shortcutHotKey(_ slot: ShortcutSlot) -> HotKey? {
        slot == .open ? openHotKey : searchHotKey
    }

    /// For `--render-bar`: `count` sample capture sizes, saving nothing.
    func setPreviewPresets(_ count: Int) {
        guard isPreview else { return }
        let sizes = [(1280, 720), (1920, 1080), (1080, 1080), (800, 600), (1200, 630), (1080, 1350)]
        presets = (0..<count).map { i in CapturePreset(width: sizes[i % sizes.count].0, height: sizes[i % sizes.count].1) }
    }

    /// For `--render --welcome`: shows the first-launch card.
    func showPreviewWelcome() {
        guard isPreview else { return }
        showWelcome = true
    }

    /// For `--render --extras`: shows the update pill and sample presets, saving nothing.
    func addPreviewExtras() {
        guard isPreview, let page = URL(string: "https://github.com/alimicious/shotshelf/releases") else { return }
        availableUpdate = AvailableUpdate(version: "9.9.9", pageURL: page, zipURL: page, signatureURL: page)
        if presets.isEmpty { presets = [CapturePreset(width: 1280, height: 720), CapturePreset(width: 1080, height: 1080, name: "Square")] }
    }

    // MARK: - Capture presets

    func newPreset() {
        presetEditor = PresetDraft()
    }

    func editPreset(_ preset: CapturePreset) {
        presetEditor = PresetDraft(preset)
    }

    func savePreset(_ preset: CapturePreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[i] = preset
        } else if presets.count < CapturePreset.limit {
            presets.append(preset)
        }
        savePresets()
        presetEditor = nil
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
        presetEditor = nil
    }

    /// Shows a frame of the preset's size to drag into place, then captures exactly that area.
    func capture(_ preset: CapturePreset) {
        // screencapture runs on ShotShelf's behalf, so it needs ShotShelf's Screen Recording permission;
        // without it the image would only show the desktop.
        guard CGPreflightScreenCaptureAccess() else {
            askForScreenRecording()
            return
        }
        closePanel?()
        let overlay = CaptureOverlay(preset: preset) { [weak self] rect in self?.takeScreenshot(of: rect) }
        captureOverlay = overlay
        overlay.show()
    }

    /// Explains what to do, since the switch can look on when it isn't: macOS may still have it set
    /// for an older copy of the app, which only removing and re-adding it fixes.
    private func askForScreenRecording() {
        CGRequestScreenCaptureAccess()  // adds ShotShelf to the list the first time
        closePanel?()
        let alert = NSAlert()
        alert.messageText = "ShotShelf needs Screen Recording to capture a set size"
        alert.informativeText = """
            In System Settings › Privacy & Security › Screen Recording, turn ShotShelf on.

            If it already looks on, macOS may still have it set for an older copy: select ShotShelf, \
            remove it with the − button, then add it again with + (or try a capture size once more).

            Then quit ShotShelf (right-click its menu bar icon) and open it again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(settings)
        }
    }

    /// Captures `rect` (global, top-left origin) into the screenshot folder, named and tagged
    /// like a macOS screenshot so it lands on the shelf like any other.
    private func takeScreenshot(of rect: CGRect) {
        captureOverlay = nil
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dest = ShotScanner.uniqueURL(in: folder, name: "Screenshot \(formatter.string(from: Date()))", ext: "png")
        let area = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        Task {
            // Give the overlay a moment to leave the screen so it isn't in the shot.
            try? await Task.sleep(for: .milliseconds(150))
            let ok = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-R", area, dest.path]
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: dest.path)
            }.value
            guard ok else {
                showToast("Couldn't take the screenshot", symbol: "exclamationmark.triangle")
                return
            }
            ShotScanner.tagAsScreenshot(dest)
            await refresh()
        }
    }

    // MARK: - Updates

    /// At most once a day, and only if automatic checks are on.
    private func checkForUpdatesIfDue() async {
        let defaults = UserDefaults.standard
        let last = Date(timeIntervalSince1970: defaults.double(forKey: Prefs.lastUpdateCheck))
        guard defaults.bool(forKey: Prefs.autoUpdates), Date().timeIntervalSince(last) > 86400 else { return }
        await checkForUpdates()
    }

    func checkForUpdates(userInitiated: Bool = false) async {
        guard updateStatus != .checking, updateStatus != .downloading, updateStatus != .installing else { return }
        updateStatus = .checking
        do {
            availableUpdate = try await Updater.check()
            updateStatus = availableUpdate == nil ? .upToDate : .idle
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheck)
        } catch {
            // A failed background check stays quiet; it'll try again tomorrow.
            updateStatus = userInitiated ? .failed("Couldn't reach GitHub. Check your connection and try again.") : .idle
        }
    }

    /// Downloads, verifies and installs the update, then relaunches into it.
    func installUpdate() {
        guard let update = availableUpdate, updateStatus != .downloading, updateStatus != .installing else { return }
        Task {
            updateStatus = .downloading
            do {
                let appURL = Bundle.main.bundleURL
                let newApp = try await Updater.prepare(update, nextTo: appURL)
                updateStatus = .installing
                try await Task.detached { try Updater.install(newApp, replacing: appURL) }.value
                Updater.relaunch(appURL)
            } catch {
                updateStatus = .failed(error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showToast(_ text: String, symbol: String, undo: Bool = false) {
        let toast = Toast(text: text, symbol: symbol, undo: undo)
        self.toast = toast
        Task {
            // One with Undo stays long enough to reach for it.
            try? await Task.sleep(for: .seconds(undo ? 6 : 1.8))
            if self.toast == toast { self.toast = nil }
        }
    }

    // MARK: - Persistence

    private static func loadPresets() -> [CapturePreset] {
        guard let data = UserDefaults.standard.data(forKey: Prefs.capturePresets) else { return [] }
        return (try? JSONDecoder().decode([CapturePreset].self, from: data)) ?? []
    }

    private func savePresets() {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: Prefs.capturePresets)
    }

    private static func loadPanelSize() -> PanelSize {
        PanelSize(rawValue: UserDefaults.standard.string(forKey: Prefs.panelSize) ?? "") ?? .medium
    }

    /// A saved shortcut; saved as JSON `null` once you've cleared it, so it doesn't fall back to the default.
    private static func loadShortcut(_ key: String, fallback: Shortcut?) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private static func loadPinned() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Prefs.pinned) ?? [])
    }

    private func savePinned() {
        UserDefaults.standard.set(Array(pinned), forKey: Prefs.pinned)
    }

    private static func loadFolders() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: Prefs.folders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Prefs.folders)
    }

    /// Recognised text and codes live in Application Support so search and quick actions work
    /// straight away after a relaunch. Tests on sample shots keep theirs beside the samples.
    private static let supportFolder: URL = {
        let dir = ShotScanner.testFolder?.appendingPathComponent(".ShotShelf", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ShotShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static var textsURL: URL { supportFolder.appendingPathComponent("text.json") }
    private static var codesURL: URL { supportFolder.appendingPathComponent("codes.json") }

    private static func loadTexts() -> [String: String] {
        guard let data = try? Data(contentsOf: textsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func loadCodes() -> [String: [String]] {
        guard let data = try? Data(contentsOf: codesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    /// Saves the text and codes read so far.
    private func saveTexts() {
        guard !isPreview else { return }
        try? JSONEncoder().encode(texts).write(to: Self.textsURL, options: .atomic)
        try? JSONEncoder().encode(codes).write(to: Self.codesURL, options: .atomic)
    }
}
