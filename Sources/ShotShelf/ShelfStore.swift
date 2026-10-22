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
    let id = UUID()
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
    @Published private(set) var texts: [String: String]
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
    /// The shot being dragged and what it's over, while rearranging or filing.
    @Published var dragging: URL?
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
    /// Up to four capture sizes, shown as pills under the header.
    @Published private(set) var presets: [CapturePreset]
    /// The add/edit form for a preset, while it's open.
    @Published var presetEditor: PresetDraft?

    let folder = ShotScanner.folder
    let mascot = MascotAnimator()
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
    private var redactWindow: NSWindow?
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
            Prefs.mascot: true,
            Prefs.autoUpdates: true,
        ])
        panelSize = Self.loadPanelSize()
        openShortcut = Self.loadShortcut(Prefs.openShortcut, fallback: Shortcut.legacy(defaults.string(forKey: Prefs.hotKey)) ?? .openDefault)
        searchShortcut = Self.loadShortcut(Prefs.searchShortcut, fallback: nil)
        pinned = Self.loadPinned()
        folders = Self.loadFolders()
        texts = Self.loadTexts()
        presets = Self.loadPresets()
        // On first launch, count only shots taken from now on as new.
        if defaults.double(forKey: Prefs.lastSeen) == 0 { defaults.set(Date().timeIntervalSince1970, forKey: Prefs.lastSeen) }
        watcher = FolderWatcher(folder) { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
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

    /// Shots that just appeared: the mascot snaps a photo, and each one's text is read and
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
        if UserDefaults.standard.bool(forKey: Prefs.mascot) { mascot.celebrate() }
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
        let lines = await Task.detached { ShotText.recognize(url) }.value
        reading.remove(url.path)
        texts[url.path] = lines.map(\.text).joined(separator: "\n")
        saveTexts()
        guard UserDefaults.standard.bool(forKey: Prefs.smartNames),
              let name = ShotText.smartName(lines, app: app, date: shot.date) else { return }
        rename(shot, to: name)
    }

    /// Reads the text of any shot that doesn't have it yet, one at a time in the background.
    private func indexText() {
        guard !isIndexing, !isPreview else { return }
        let missing = shots.filter { texts[$0.url.path] == nil && !reading.contains($0.url.path) }
        guard !missing.isEmpty else { return }
        isIndexing = true
        indexing = missing.count
        Task {
            for shot in missing {
                let url = shot.url
                let text = await Task.detached(priority: .utility) {
                    ShotText.recognize(url).map(\.text).joined(separator: "\n")
                }.value
                if FileManager.default.fileExists(atPath: url.path) { texts[url.path] = text }
                indexing -= 1
            }
            let live = Set(shots.map(\.url.path))
            texts = texts.filter { live.contains($0.key) }
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

    /// Previews `shot`; the arrow keys in Quick Look then step through `list` (the whole shelf by default).
    func quickLook(_ shot: Shot, among list: [Shot]? = nil) {
        let list = list ?? shots
        AppDelegate.toggleQuickLook(list.map(\.url), at: list.firstIndex(of: shot) ?? 0)
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

    func trash(_ shot: Shot) {
        trash([shot])
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
        saveTexts()
        var order = UserDefaults.standard.stringArray(forKey: Prefs.order) ?? []
        if let i = order.firstIndex(of: old) {
            order[i] = new
            UserDefaults.standard.set(order, forKey: Prefs.order)
        }
        if hovered == shot.url { hovered = dest }
        Task { await refresh() }
    }

    // MARK: - Redact

    func redact(_ shot: Shot) {
        guard let model = RedactModel(shot: shot) else {
            showToast("Couldn't open that shot", symbol: "exclamationmark.triangle")
            return
        }
        redactWindow?.close()
        closePanel?()
        let view = RedactView(
            model: model,
            onCopy: { [weak self] data in
                self?.copyImageData(data)
                self?.redactWindow?.close()
            },
            onSave: { [weak self] data in
                self?.saveRedacted(data, from: shot)
                self?.redactWindow?.close()
            })

        // Fit the shot in at most 960×640, plus room for the padding and toolbar.
        let width = min(960, 640 * model.aspect)
        let size = NSSize(width: max(520, width + 32), height: max(380, width / model.aspect + 32 + 56))
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Redact – \(shot.url.deletingPathExtension().lastPathComponent)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        redactWindow = window
    }

    private func copyImageData(_ data: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        showToast("Copied redacted image", symbol: "eye.slash")
    }

    /// Saves next to the original as "… (redacted).png", tagged as a screenshot so it lands on the shelf.
    private func saveRedacted(_ data: Data, from shot: Shot) {
        let name = shot.url.deletingPathExtension().lastPathComponent + " (redacted)"
        let dest = ShotScanner.uniqueURL(in: shot.url.deletingLastPathComponent(), name: name, ext: "png")
        handled.insert(dest.path)
        do {
            try data.write(to: dest)
            ShotScanner.tagAsScreenshot(dest)
            showToast("Saved a redacted copy", symbol: "eye.slash")
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

    /// Moves a shot into one of the folders, which takes it off the shelf.
    func file(_ shot: Shot, into folder: URL) {
        let name = shot.url.deletingPathExtension().lastPathComponent
        let dest = ShotScanner.uniqueURL(in: folder, name: name, ext: shot.url.pathExtension)
        do {
            try FileManager.default.moveItem(at: shot.url, to: dest)
        } catch {
            showToast("Couldn't move it to \(folder.lastPathComponent)", symbol: "exclamationmark.triangle")
            return
        }
        if pinned.remove(shot.url.path) != nil { savePinned() }
        texts[shot.url.path] = nil
        showToast("Moved to \(folder.lastPathComponent)", symbol: "folder.fill")
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
        trash(shots.filter { $0.date < cutoff && !isPinned($0) })
    }

    /// Moves files to the Trash (never deletes them outright), so anything tidied can be put back.
    private func trash(_ victims: [Shot]) {
        guard !victims.isEmpty else { return }
        for shot in victims {
            try? FileManager.default.trashItem(at: shot.url, resultingItemURL: nil)
            pinned.remove(shot.url.path)
        }
        savePinned()
        Task { await refresh() }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let shots = Array(visible)
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 {  // Escape
            closePanel?()
            return true
        }
        if key == "f", mods == .command {
            showAll = true
            return true
        }
        guard !shots.isEmpty else { return false }
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

        if event.keyCode == 53 {  // Escape: clear the search first, then close
            if inField, !query.isEmpty { query = "" } else { showAll = false }
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
    /// through `list`), Return opens, Delete trashes, ⌘C copies, T copies text, P pins, R redacts.
    private func act(on shot: Shot, in list: [Shot], event: NSEvent, select: (URL?) -> Void) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, mods, key) {
        case (49, [], _): quickLook(shot, among: list)                    // Space
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
        case (_, [], "r"): redact(shot)
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
            CGRequestScreenCaptureAccess()
            showToast("Allow ShotShelf in Screen Recording, then try again", symbol: "rectangle.dashed.badge.record")
            if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(settings)
            }
            return
        }
        closePanel?()
        let overlay = CaptureOverlay(preset: preset) { [weak self] rect in self?.takeScreenshot(of: rect) }
        captureOverlay = overlay
        overlay.show()
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

    func showToast(_ text: String, symbol: String) {
        let toast = Toast(text: text, symbol: symbol)
        self.toast = toast
        Task {
            try? await Task.sleep(for: .seconds(1.8))
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

    /// Recognised text lives in Application Support so search works straight away after a relaunch.
    private static let textsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("text.json")
    }()

    private static func loadTexts() -> [String: String] {
        guard let data = try? Data(contentsOf: textsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveTexts() {
        guard !isPreview else { return }
        try? JSONEncoder().encode(texts).write(to: Self.textsURL, options: .atomic)
    }
}
