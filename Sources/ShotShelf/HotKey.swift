import AppKit
import Carbon.HIToolbox
import Quartz

/// A key combination for a global shortcut, in Carbon's terms, plus how to show it.
struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, …).
    let modifiers: UInt32
    let display: String

    static let openDefault = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | cmdKey), display: "⌥⌘S")
}

extension Shortcut {
    /// Builds a shortcut from a key press. Nil without ⌘, ⌥ or ⌃, since a plain key would hijack typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isDisjoint(with: [.command, .option, .control]), let key = Self.keyName(event) else { return nil }
        var modifiers = 0
        var symbols = ""
        if flags.contains(.control) { modifiers |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; symbols += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), display: symbols + key)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key's label as printed on the keyboard, so ⇧⌘7 shows as "7" rather than "&".
    private static func keyName(_ event: NSEvent) -> String? {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        guard let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty,
              !chars.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return chars.uppercased()
    }

    /// The shortcut picked from the old fixed list, before shortcuts could be recorded.
    static func legacy(_ preset: String?) -> Shortcut?? {
        switch preset {
        case "⌥⌘S": return .some(.openDefault)
        case "⇧⌘6": return .some(Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(shiftKey | cmdKey), display: "⇧⌘6"))
        case "⌃⌥⌘S": return .some(Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘S"))
        case "Off": return .some(nil)
        default: return nil
        }
    }
}

/// A system-wide shortcut via Carbon's hot key API, which (unlike a global key monitor)
/// needs no Accessibility or Input Monitoring permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_4C46), id: id)  // "SHLF"
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
        else { return nil }
        Self.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    /// One handler for every shortcut; it looks up which one fired by its ID.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The panel's three sizes. Bigger panels get bigger tiles and more of them.
enum PanelSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .small: return 320
        case .medium: return 360
        case .large: return 464
        }
    }

    var columns: Int { self == .large ? 4 : 3 }

    var rows: Int {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .large: return 3
        }
    }

    /// The big slot plus the rows of small tiles under it.
    var slots: Int { 1 + columns * rows }

    /// Tiles share the width inside the 16pt padding, 8pt apart, at roughly a screen's aspect ratio.
    var tile: CGSize {
        let w = (width - 32 - CGFloat(columns - 1) * 8) / CGFloat(columns)
        return CGSize(width: w, height: (w * 0.67).rounded())
    }

    var hero: CGSize {
        let w = width - 32
        return CGSize(width: w, height: (w * 0.56).rounded())
    }
}

/// Quick Look looks for a controller along the responder chain, which ends at the app delegate,
/// so the delegate takes that role and feeds the panel whatever the shelf asks to preview.
final class AppDelegate: NSObject, NSApplicationDelegate, QLPreviewPanelDataSource {
    static private(set) var shared: AppDelegate?
    private var items: [URL] = []
    /// Moves the shelf's or search's highlight to the shot Quick Look is showing.
    private var follow: ((URL) -> Void)?
    private var followedIndex = -1
    private var followTimer: Timer?
    /// For `--selftest`: the item Quick Look held at the moment it went on screen.
    static private(set) var itemWhenShown: URL?
    private(set) var statusController: StatusController?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController(store: ShelfStore())
    }

    @MainActor static func toggleQuickLook(_ urls: [URL], at index: Int, follow: ((URL) -> Void)? = nil) {
        guard let panel = QLPreviewPanel.shared(), let delegate = shared else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        delegate.follow = follow
        delegate.followedIndex = index
        delegate.items = urls
        // Load the right shot before the panel shows. Showing it first flashed whatever it showed
        // last time for a moment, until the new item arrived.
        panel.dataSource = delegate
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        itemWhenShown = panel.currentPreviewItem as? URL
        // Taking control on the way in can reset the item, so make sure it's still the one asked for.
        if panel.currentPreviewItemIndex != index { panel.currentPreviewItemIndex = index }
        delegate.startFollowing()
    }

    /// Quick Look has no callback for stepping to another item, so this checks a few times a second
    /// while it's open and passes any change on.
    @MainActor private func startFollowing() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.checkFollowedItem() }
        }
    }

    @MainActor private func checkFollowedItem() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else {
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        let index = panel.currentPreviewItemIndex
        guard index != followedIndex, items.indices.contains(index) else { return }
        followedIndex = index
        follow?(items[index])
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Already set up by toggleQuickLook; setting it again would reload and reset the item.
        if panel.dataSource !== self { panel.dataSource = self }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}
