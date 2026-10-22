import AppKit
import Combine
import SwiftUI

/// The menu bar item and its panel, built by hand rather than with MenuBarExtra: that has no way
/// to open its panel from code, which the global shortcut needs. The panel sits on a real
/// Liquid Glass surface, like the system's own menu bar extras.
@MainActor
final class StatusController: NSObject {
    let store: ShelfStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: ShelfPanel
    private let hosting: NSHostingView<ShelfView>
    /// Search lives in its own panel beside the shelf, so Quick Look and drags don't close it.
    private let searchPanel: ShelfPanel
    private let searchHosting: NSHostingView<AllShotsView>
    /// The capture bar floating under the shelf, Spotlight style: a big glass capsule with the
    /// capture sizes and a round + beside it, in one glass container so they blend together.
    private let bar: ShelfPanel
    private let barCapsule = NSGlassEffectView()
    /// The + circle. Adding or editing a size grows this same piece of glass into the editor card,
    /// so the form comes out of the +, and shrinks it back when the form closes.
    private let barCircle = NSGlassEffectView()
    /// Holds the + and, while it's open, the editor; clipped to the glass's rounded shape.
    private let circleContent = NSView()
    private let plusHosting: NSHostingView<AddSizeButton>
    private var editorHosting: NSView?
    private static let barHeight: CGFloat = 52
    private static let barGap: CGFloat = 10
    private var clickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []

    init(store: ShelfStore) {
        self.store = store
        hosting = NSHostingView(rootView: ShelfView(store: store))
        panel = ShelfPanel(contentView: Self.glassSurface(hosting), size: hosting.fittingSize)
        searchHosting = NSHostingView(rootView: AllShotsView(store: store))
        searchPanel = ShelfPanel(contentView: Self.glassSurface(searchHosting), size: searchHosting.fittingSize)
        barCapsule.cornerRadius = Self.barHeight / 2
        barCapsule.contentView = NSHostingView(rootView: CaptureBarView(store: store))
        barCircle.cornerRadius = Self.barHeight / 2
        plusHosting = NSHostingView(rootView: AddSizeButton(store: store))
        plusHosting.autoresizingMask = [.width, .height]
        circleContent.wantsLayer = true
        circleContent.layer?.cornerRadius = Self.barHeight / 2
        circleContent.layer?.masksToBounds = true
        circleContent.addSubview(plusHosting)
        barCircle.contentView = circleContent
        let barStack = NSView()
        barStack.addSubview(barCapsule)
        barStack.addSubview(barCircle)
        let barContainer = NSGlassEffectContainerView()
        barContainer.spacing = 8  // less than the gap, so the pieces stay apart at rest
        barContainer.contentView = barStack
        Self.catchClicks(on: barContainer, cornerRadius: Self.barHeight / 2)
        bar = ShelfPanel(contentView: barContainer, size: NSSize(width: 360, height: Self.barHeight))
        super.init()

        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        store.panelWindow = panel
        store.searchWindow = searchPanel
        store.togglePanel = { [weak self] in self?.toggle() }
        store.closePanel = { [weak self] in self?.close() }

        // Keep the menu bar icon in step with its animation and the new-shot badge.
        store.iconAnimator.$frame.combineLatest(store.$newCount)
            .sink { [weak self] frame, count in
                MainActor.assumeIsolated { self?.updateButton(frame: frame, count: count) }
            }
            .store(in: &subscriptions)

        // Switching size in Settings resizes the open panel, once SwiftUI has laid out the new grid.
        store.$panelSize.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    MainActor.assumeIsolated {
                        guard let self, self.panel.isVisible else { return }
                        self.place()
                    }
                }
            }
            .store(in: &subscriptions)

        // The + goes away once all 20 sizes are taken, and the capsule widens to fill its place.
        store.$presets.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layoutBar() } }
            }
            .store(in: &subscriptions)

        store.$presetEditor.dropFirst()
            .sink { [weak self] draft in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let draft { self?.openEditor(draft) } else { self?.closeEditor() }
                    }
                }
            }
            .store(in: &subscriptions)

        store.$showAll.dropFirst().removeDuplicates()
            .sink { [weak self] show in
                MainActor.assumeIsolated { show ? self?.showSearch() : self?.hideSearch() }
            }
            .store(in: &subscriptions)

        // On first launch the shelf opens by itself, with the welcome card.
        if store.showWelcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self.show() }
            }
        }
    }

    /// Opens search beside the shelf: to its left, or its right when there's no room.
    private func showSearch() {
        if !panel.isVisible { show() }
        let size = searchHosting.fittingSize
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var x = panel.frame.minX - 10 - size.width
        if x < visible.minX + 8 { x = panel.frame.maxX + 10 }
        searchPanel.setFrame(NSRect(x: x, y: panel.frame.maxY - size.height, width: size.width, height: size.height),
                             display: true)
        searchPanel.makeKeyAndOrderFront(nil)
    }

    private func hideSearch() {
        searchPanel.orderOut(nil)
        if panel.isVisible { panel.makeKey() }
    }

    private func updateButton(frame: ShelfIcon.Frame, count: Int) {
        item.button?.image = ShelfIcon.image(frame: frame)
        item.button?.title = count > 0 ? "\(count)" : ""
    }

    /// A panel's rounded glass, inside a glass container like the capture bar's pieces. Glass renders
    /// its edge differently in and out of a container, so every surface goes through one.
    static func glassSurface(_ content: NSView, cornerRadius: CGFloat = 24) -> NSView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        glass.autoresizingMask = [.width, .height]
        let container = NSGlassEffectContainerView()
        container.contentView = glass
        container.wantsLayer = true
        Self.catchClicks(on: container, cornerRadius: glass.cornerRadius)
        return container
    }

    /// The glass is drawn by the window server, not into the window's own pixels, and macOS 26 lets
    /// clicks fall through a transparent window wherever its pixels are see-through, so they went to
    /// the app behind. A practically invisible backing, shaped like the glass, gives every click a
    /// pixel to land on (ShelfPanel also opts out of click-through outright).
    private static func catchClicks(on view: NSView, cornerRadius: CGFloat) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        view.layer?.cornerRadius = cornerRadius
    }

    /// For `--selftest`: whether the shelf's glass fills its window.
    var panelSummary: String {
        let glass = (panel.contentView as? NSGlassEffectContainerView)?.contentView?.frame ?? .zero
        return "window \(Int(panel.frame.width))×\(Int(panel.frame.height)), glass \(Int(glass.width))×\(Int(glass.height)), content \(Int(hosting.frame.width))×\(Int(hosting.frame.height))"
    }

    /// For `--selftest`: the capture bar window and the + glass, to check the editor morph.
    var barSummary: String {
        let c = barCircle.frame
        return "window \(Int(bar.frame.width))×\(Int(bar.frame.height)), + glass \(Int(c.width))×\(Int(c.height)) at (\(Int(c.minX)),\(Int(c.minY))), key=\(bar.isKeyWindow)"
    }

    /// Left-click opens or closes the shelf; right-click (or Control-click) shows a small menu with Quit.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseUp || event.modifierFlags.contains(.control) else {
            toggle()
            return
        }
        showStatusMenu()
    }

    private func showStatusMenu() {
        guard let button = item.button else { return }
        close()
        let menu = NSMenu()
        let version = NSMenuItem(title: "ShotShelf \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ShotShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        button.highlight(false)
    }

    @objc func toggle() {
        panel.isVisible ? close() : show()
    }

    private func show() {
        guard let button = item.button else { return }
        store.panelOpened()
        place()
        panel.makeKeyAndOrderFront(nil)
        bar.orderFront(nil)
        button.highlight(true)
        // Clicking anywhere in another app closes the panel, the way menus behave.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Sizes the panel to its content and hangs it just below the icon like a menu, nudged to stay on screen.
    private func place() {
        guard let button = item.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height),
                       display: true, animate: panel.isVisible)
        bar.setFrame(NSRect(x: x, y: panel.frame.minY - Self.barGap - Self.barHeight, width: size.width, height: Self.barHeight),
                     display: true)
        layoutBar()
    }

    /// Capsule on the left, circle on the right, both along the top of the bar's window (which grows
    /// downward while the editor is open). The capsule takes the whole width once the + is gone.
    private func layoutBar() {
        let width = bar.frame.width, height = bar.frame.height, h = Self.barHeight
        let hasRoom = store.presets.count < CapturePreset.limit
        barCircle.isHidden = !hasRoom && editorHosting == nil
        if editorHosting == nil { barCircle.frame = NSRect(x: width - h, y: height - h, width: h, height: h) }
        barCapsule.frame = NSRect(x: 0, y: height - h, width: hasRoom ? width - h - Self.barGap : width, height: h)
        barCapsule.superview?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for glass in [barCapsule, barCircle] {
            glass.contentView?.frame = glass.bounds
            glass.contentView?.autoresizingMask = [.width, .height]
        }
    }

    /// Grows the + into the editor card below the bar, with a little overshoot, fading the form in.
    private func openEditor(_ draft: PresetDraft) {
        guard bar.isVisible else { return }
        editorHosting?.removeFromSuperview()
        let form = NSHostingView(rootView: PresetEditor(draft: draft, store: store))
        let size = form.fittingSize
        let h = Self.barHeight
        // Make room below the bar first, keeping the bar itself where it is.
        let top = bar.frame.maxY, width = bar.frame.width
        bar.setFrame(NSRect(x: bar.frame.minX, y: top - h - Self.barGap - size.height,
                            width: width, height: h + Self.barGap + size.height), display: true)
        layoutBar()

        // The form stays pinned to the glass's top-right corner as the glass grows out from under it.
        let glass = barCircle.bounds
        form.frame = NSRect(x: glass.maxX - size.width, y: glass.maxY - size.height, width: size.width, height: size.height)
        form.autoresizingMask = [.minXMargin, .minYMargin]
        form.alphaValue = 0
        circleContent.addSubview(form)
        editorHosting = form
        barCircle.isHidden = false
        bar.makeKey()  // so the fields take typing

        let card = NSRect(x: width - size.width, y: 0, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.15, 0.45, 1)  // springy, slight overshoot
            context.allowsImplicitAnimation = true
            barCircle.animator().frame = card
            plusHosting.animator().alphaValue = 0
            form.animator().alphaValue = 1
        }
    }

    /// Shrinks the card back into the +, then gives the window back its bar-only size.
    private func closeEditor() {
        guard let form = editorHosting else { return }
        let h = Self.barHeight
        let circle = NSRect(x: bar.frame.width - h, y: bar.frame.height - h, width: h, height: h)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            context.allowsImplicitAnimation = true
            barCircle.animator().frame = circle
            plusHosting.animator().alphaValue = 1
            form.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                form.removeFromSuperview()
                guard self.editorHosting === form else { return }  // a new form opened meanwhile
                self.editorHosting = nil
                let frame = self.bar.frame
                self.bar.setFrame(NSRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h), display: true)
                self.layoutBar()
                if self.panel.isVisible { self.panel.makeKey() }
            }
        })
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        bar.orderOut(nil)
        item.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        store.showSettings = false
        store.showUpdate = false
        store.cancelRecording()
        store.showAll = false
        store.presetEditor = nil
        store.hovered = nil
        store.selection = []
    }
}

/// A borderless panel that can take key presses without pulling focus from the app you're in.
final class ShelfPanel: NSPanel {
    init(contentView: NSView, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        // Set explicitly: left at its default, a transparent window passes clicks through any
        // see-through pixels, and on macOS 26 that included the glass.
        ignoresMouseEvents = false
        // No window shadow: macOS works it out from the window's rectangle (and before the glass has
        // drawn, on first open), which leaves hard square corners around rounded glass. The glass
        // gives every panel the same soft rounded edge instead.
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}
