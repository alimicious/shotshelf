import AppKit
import SwiftUI
import VisionKit

/// A screenshot kept on screen above your other windows, to refer to while you work. It sits in a
/// thin glass frame: drag it to move it, pinch or drag an edge to resize it, hover for its controls
/// (Live Text, see-through, copy, close), double-click to open it, and press Esc to close it.
@MainActor
final class FloatingShot: NSObject, NSWindowDelegate {
    let window: FloatingPanel
    let model = FloatModel()
    private let onClose: (FloatingShot) -> Void
    /// The frame when a pinch began, which the pinch scales.
    private var pinchStart: NSRect?

    init?(shot: Shot, cascade: Int, onCopy: @escaping () -> Void, onClose: @escaping (FloatingShot) -> Void) {
        guard let source = CGImageSourceCreateWithURL(shot.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelsWide = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelsHigh = props[kCGImagePropertyPixelHeight] as? CGFloat,
              let image = ShotScanner.thumbnail(shot.url, maxPixels: 3000) else { return nil }
        // Its real size in points on the screen you're on, shrunk to fit a comfortable corner of it.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let fit = min(1, 520 / (pixelsWide / scale), 400 / (pixelsHigh / scale))
        let size = NSSize(width: (pixelsWide / scale * fit).rounded() + 12, height: (pixelsHigh / scale * fit).rounded() + 12)

        self.onClose = onClose
        let hosting = NSHostingView(rootView: FloatingShotView(image: image, model: model))
        window = FloatingPanel(contentView: StatusController.glassSurface(hosting, cornerRadius: 18), size: size)
        super.init()
        window.delegate = self
        window.contentAspectRatio = size
        window.minSize = NSSize(width: 120, height: 120 * size.height / size.width)
        if let visible = screen?.visibleFrame {
            let step = CGFloat(cascade % 8) * 24
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2 + step, y: visible.midY - size.height / 2 + 60 - step))
        }

        model.copy = { [weak model] in
            onCopy()
            model?.copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                model?.copied = false
            }
        }
        model.toggleSeeThrough = { [weak self] in
            guard let self else { return }
            model.seeThrough.toggle()
            window.alphaValue = model.seeThrough ? 0.5 : 1
        }
        model.open = { NSWorkspace.shared.open(shot.url) }
        model.close = { [weak self] in self?.window.close() }
        model.pinch = { [weak self] in self?.pinch($0) }
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// Esc or ⌘W closes, ⌘C copies.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, mods, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, [], _), (_, .command, "w"): window.close()
        case (_, .command, "c"): model.copy()
        default: return false
        }
        return true
    }

    /// Scales the window about its centre while a pinch goes on; nil when the pinch ends.
    private func pinch(_ magnification: CGFloat?) {
        guard let magnification else {
            pinchStart = nil
            return
        }
        let start = pinchStart ?? window.frame
        pinchStart = start
        let maxWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 2000
        let width = min(max(start.width * magnification, window.minSize.width), maxWidth)
        let height = width * start.height / start.width
        window.setFrame(NSRect(x: start.midX - width / 2, y: start.midY - height / 2, width: width, height: height), display: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }
}

/// State and actions for a floating shot's controls.
@MainActor
final class FloatModel: ObservableObject {
    @Published var hovered = false
    @Published var seeThrough = false
    @Published var copied = false
    var copy: () -> Void = {}
    var toggleSeeThrough: () -> Void = {}
    var open: () -> Void = {}
    var close: () -> Void = {}
    var pinch: (CGFloat?) -> Void = { _ in }
    /// Live Text is on: the shot's text can be selected, its links opened and its subject lifted,
    /// and dragging selects instead of moving the window.
    @Published var liveText = false
    /// What Live Text found, kept so turning it back on is instant.
    var analysis: ImageAnalysis?
}

private struct FloatingShotView: View {
    let image: NSImage
    @ObservedObject var model: FloatModel

    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .overlay { if model.liveText { LiveTextOverlay(image: image, model: model) } }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(MagnifyGesture()
                .onChanged { model.pinch($0.magnification) }
                .onEnded { _ in model.pinch(nil) })
            .onTapGesture(count: 2) { model.open() }
            .overlay(alignment: .topTrailing) { if model.hovered { controls } }
            .onHover { inside in withAnimation(.spring(duration: 0.28, bounce: 0.25)) { model.hovered = inside } }
            .help("Drag to move · pinch or drag an edge to resize · double-click to open · Esc closes")
    }

    private var controls: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                if ImageAnalyzer.isSupported {
                    control(model.liveText ? "text.viewfinder.fill" : "text.viewfinder",
                            help: model.liveText ? "Done selecting text, so dragging moves the shot again"
                                                 : "Live Text: select text, open links or lift the subject",
                            action: { model.liveText.toggle() })
                    .foregroundStyle(model.liveText ? AnyShapeStyle(Color(nsColor: ShelfIcon.terracotta)) : AnyShapeStyle(.primary))
                }
                control(model.seeThrough ? "circle.fill" : "circle.lefthalf.filled",
                        help: model.seeThrough ? "Make solid" : "See through", action: model.toggleSeeThrough)
                control(model.copied ? "checkmark" : "doc.on.doc", help: "Copy image (⌘C)", action: model.copy)
                control("xmark", help: "Close (Esc)", action: model.close)
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(12)
        .transition(.scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity))
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Apple's Live Text over a floating shot, analysed on your Mac: select and copy text, open links
/// and codes, look things up, and right-click to copy the subject. It takes the shot's clicks while
/// it's on, which is why it's a mode.
private struct LiveTextOverlay: NSViewRepresentable {
    let image: NSImage
    let model: FloatModel

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = .automatic
        if let analysis = model.analysis {
            overlay.analysis = analysis
            overlay.selectableItemsHighlighted = true
        } else {
            Task { @MainActor in
                let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
                guard let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
                else { return }
                model.analysis = analysis
                overlay.analysis = analysis
                // Show what can be selected, the way Preview does when Live Text turns on.
                overlay.selectableItemsHighlighted = true
            }
        }
        return overlay
    }

    func updateNSView(_ overlay: ImageAnalysisOverlayView, context: Context) {}
}

/// A floating shot's window: borderless glass above other apps' windows, on every Space, resizable
/// from its edges, and able to take keys without pulling focus from the app you're in.
final class FloatingPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    init(contentView: NSView, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        // The same glass fixes as the shelf's panels (see ShelfPanel).
        ignoresMouseEvents = false
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
