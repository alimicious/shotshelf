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
    private let barCircle = NSGlassEffectView()
    private static let barHeight: CGFloat = 52
    private static let barGap: CGFloat = 10
    private var clickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []

    init(store: ShelfStore) {
        self.store = store
        hosting = NSHostingView(rootView: ShelfView(store: store))
        let glass = NSGlassEffectView()
        glass.cornerRadius = 24
        glass.contentView = hosting
        panel = ShelfPanel(contentView: glass, size: hosting.fittingSize)
        searchHosting = NSHostingView(rootView: AllShotsView(store: store))
        let searchGlass = NSGlassEffectView()
        searchGlass.cornerRadius = 24
        searchGlass.contentView = searchHosting
        searchPanel = ShelfPanel(contentView: searchGlass, size: searchHosting.fittingSize)
        barCapsule.cornerRadius = Self.barHeight / 2
        barCapsule.contentView = NSHostingView(rootView: CaptureBarView(store: store))
        barCircle.cornerRadius = Self.barHeight / 2
        barCircle.contentView = NSHostingView(rootView: AddSizeButton(store: store))
        let barStack = NSView()
        barStack.addSubview(barCapsule)
        barStack.addSubview(barCircle)
        let barContainer = NSGlassEffectContainerView()
        barContainer.spacing = 12
        barContainer.contentView = barStack
        bar = ShelfPanel(contentView: barContainer, size: NSSize(width: 360, height: Self.barHeight))
        bar.hasShadow = false  // the glass draws its own
        super.init()

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        store.panelWindow = panel
        store.searchWindow = searchPanel
        store.togglePanel = { [weak self] in self?.toggle() }
        store.closePanel = { [weak self] in self?.close() }

        // Keep the menu bar icon in step with the mascot and the new-shot badge.
        store.mascot.$frame.combineLatest(store.$newCount)
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

        // The + goes away once all four sizes are taken, and the capsule widens to fill its place.
        store.$presets.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layoutBar() } }
            }
            .store(in: &subscriptions)

        store.$showAll.dropFirst().removeDuplicates()
            .sink { [weak self] show in
                MainActor.assumeIsolated { show ? self?.showSearch() : self?.hideSearch() }
            }
            .store(in: &subscriptions)
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

    /// Capsule on the left, circle on the right; the capsule takes the whole width when the + is hidden.
    private func layoutBar() {
        let width = bar.frame.width, h = Self.barHeight
        let showCircle = store.presets.count < CapturePreset.limit
        barCircle.isHidden = !showCircle
        barCircle.frame = NSRect(x: width - h, y: 0, width: h, height: h)
        barCapsule.frame = NSRect(x: 0, y: 0, width: showCircle ? width - h - Self.barGap : width, height: h)
        barCapsule.superview?.frame = NSRect(x: 0, y: 0, width: width, height: h)
        for glass in [barCapsule, barCircle] {
            glass.contentView?.frame = glass.bounds
            glass.contentView?.autoresizingMask = [.width, .height]
        }
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
        store.hovered = nil
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
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}
