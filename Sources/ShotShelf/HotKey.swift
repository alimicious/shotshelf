import AppKit
import Carbon.HIToolbox
import Quartz

/// The shortcuts offered for opening the shelf from anywhere.
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionCommandS = "⌥⌘S"
    case shiftCommand6 = "⇧⌘6"
    case controlOptionCommandS = "⌃⌥⌘S"
    case off = "Off"
    var id: String { rawValue }

    fileprivate var key: (code: Int, modifiers: Int)? {
        switch self {
        case .optionCommandS: return (kVK_ANSI_S, optionKey | cmdKey)
        case .shiftCommand6: return (kVK_ANSI_6, shiftKey | cmdKey)
        case .controlOptionCommandS: return (kVK_ANSI_S, controlKey | optionKey | cmdKey)
        case .off: return nil
        }
    }
}

/// A system-wide shortcut via Carbon's hot key API, which (unlike a global key monitor)
/// needs no Accessibility or Input Monitoring permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?
    private static var handlerInstalled = false

    init?(_ preset: HotKeyPreset, action: @escaping () -> Void) {
        guard let key = preset.key else { return nil }
        Self.action = action
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5348_4C46), id: 1)  // "SHLF"
        guard RegisterEventHotKey(UInt32(key.code), UInt32(key.modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr
        else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}

/// Quick Look looks for a controller along the responder chain, which ends at the app delegate,
/// so the delegate takes that role and feeds the panel whatever the shelf asks to preview.
final class AppDelegate: NSObject, NSApplicationDelegate, QLPreviewPanelDataSource {
    static private(set) var shared: AppDelegate?
    private var items: [URL] = []
    private(set) var statusController: StatusController?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController(store: ShelfStore())
    }

    @MainActor static func toggleQuickLook(_ urls: [URL], at index: Int) {
        guard let panel = QLPreviewPanel.shared(), let delegate = shared else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        delegate.items = urls
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // In case Quick Look didn't find us on the responder chain (no key window, say).
        if panel.dataSource == nil { panel.dataSource = delegate }
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}
