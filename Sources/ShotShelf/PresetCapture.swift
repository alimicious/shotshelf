import AppKit
import SwiftUI

private let terracotta = Color(nsColor: ShelfIcon.terracotta)

/// A saved capture size. Sizes are in points, like the ⌘⇧5 selection's readout, so on a
/// Retina screen the image comes out at twice as many pixels.
struct CapturePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var width: Int
    var height: Int
    var name = ""

    var label: String { name.isEmpty ? "\(width) × \(height)" : name }

    static let limit = 20
    static let suggestions = [(1280, 720), (1920, 1080), (1080, 1080), (800, 600)]
}

/// The add/edit form's fields, kept as text while you type.
@MainActor
final class PresetDraft: ObservableObject {
    let id: UUID?
    @Published var width: String
    @Published var height: String
    @Published var name: String

    init(_ preset: CapturePreset? = nil) {
        id = preset?.id
        width = preset.map { "\($0.width)" } ?? ""
        height = preset.map { "\($0.height)" } ?? ""
        name = preset?.name ?? ""
    }

    var preset: CapturePreset? {
        guard let w = Int(width), let h = Int(height), (16...10000).contains(w), (16...10000).contains(h) else { return nil }
        return CapturePreset(id: id ?? UUID(), width: w, height: h, name: name.trimmingCharacters(in: .whitespaces))
    }
}

/// The add/edit form. It lives in the glass that grows out of the bar's + (see StatusController).
struct PresetEditor: View {
    @ObservedObject var draft: PresetDraft
    @ObservedObject var store: ShelfStore
    @FocusState private var widthFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == nil ? "New capture size" : "Edit capture size").font(.headline)
            HStack(spacing: 6) {
                TextField("Width", text: $draft.width).frame(width: 72).focused($widthFocused)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", text: $draft.height).frame(width: 72)
                Text("pt").foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            TextField("Name (optional)", text: $draft.name).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                ForEach(CapturePreset.suggestions, id: \.0) { w, h in
                    Button("\(w)×\(h)") {
                        draft.width = "\(w)"
                        draft.height = "\(h)"
                    }
                    .buttonStyle(.glass).controlSize(.mini)
                }
            }
            Text("Sizes are in points, like the ⌘⇧5 selection. On a Retina screen the image has twice as many pixels.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let id = draft.id {
                    Button("Delete", role: .destructive) { store.deletePreset(id) }.buttonStyle(.glass)
                }
                Spacer()
                Button("Cancel") { store.presetEditor = nil }
                    .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save") { draft.preset.map(store.savePreset) }
                    .buttonStyle(.glassProminent).tint(terracotta)
                    .disabled(draft.preset == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 310)
        .onAppear { widthFocused = true }
    }
}

/// What's inside the capture bar's big capsule, Spotlight style: a viewfinder, then your sizes
/// in large type (click one to capture), or a "Capture sizes" placeholder before there are any.
struct CaptureBarView: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
            if store.presets.isEmpty {
                Button { store.newPreset() } label: {
                    Text("Capture sizes")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Save a screenshot size you can capture in one click")
            } else {
                // All sizes in a row when they fit; otherwise a sideways scroll whose edges fade out,
                // so it's clear there are more.
                ViewThatFits(in: .horizontal) {
                    chips
                    ScrollView(.horizontal, showsIndicators: false) { chips.padding(.horizontal, 8) }
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                                     .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .padding(.leading, 18).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var chips: some View {
        HStack(spacing: 2) {
            ForEach(Array(store.presets.enumerated()), id: \.element.id) { index, preset in
                if index > 0 { Divider().frame(height: 20) }
                PresetChip(preset: preset, store: store)
            }
        }
        .fixedSize()
    }
}

private struct PresetChip: View {
    let preset: CapturePreset
    @ObservedObject var store: ShelfStore

    private var isHovered: Bool { store.hoveredPreset == preset.id }

    var body: some View {
        Button { store.capture(preset) } label: {
            Text(preset.label)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { store.hoveredPreset = preset.id } else if isHovered { store.hoveredPreset = nil }
        }
        .help("Capture a \(preset.width) × \(preset.height) area. Right-click to edit.")
        .contextMenu {
            Button("Edit…") { store.editPreset(preset) }
            Button("Delete", role: .destructive) { store.deletePreset(preset.id) }
        }
    }
}

/// The round + beside the capsule, like Spotlight's buttons.
struct AddSizeButton: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        Button { store.newPreset() } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Add a capture size")
    }
}

/// A frame of the preset's size over a dimmed screen, like the ⌘⇧5 selection: drag it into
/// place, then Capture (or Return). Esc cancels.
@MainActor
final class CaptureOverlay: ObservableObject {
    let preset: CapturePreset
    /// The frame, in the overlay's coordinates (top-left origin, points).
    @Published var rect: CGRect
    var dragStart: CGPoint?
    private let screen: NSScreen
    private var window: ShelfPanel?
    private let onCapture: (CGRect) -> Void

    /// Opens on the screen under the pointer. `onCapture` gets the frame in global screen
    /// coordinates (top-left origin), ready for `screencapture -R`.
    init(preset: CapturePreset, onCapture: @escaping (CGRect) -> Void) {
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        self.preset = preset
        self.onCapture = onCapture
        let size = CGSize(width: min(CGFloat(preset.width), screen.frame.width),
                          height: min(CGFloat(preset.height), screen.frame.height))
        rect = CGRect(x: (screen.frame.width - size.width) / 2, y: (screen.frame.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func show() {
        let window = ShelfPanel(contentView: NSHostingView(rootView: CaptureOverlayView(model: self)), size: screen.frame.size)
        window.level = .screenSaver
        window.setFrame(screen.frame, display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func cancel() {
        window?.orderOut(nil)
        window = nil
    }

    func capture() {
        // macOS counts y from the top of the primary display.
        let primaryHeight = NSScreen.screens[0].frame.height
        let global = CGRect(x: screen.frame.minX + rect.minX,
                            y: primaryHeight - screen.frame.maxY + rect.minY,
                            width: rect.width, height: rect.height)
        cancel()
        onCapture(global)
    }

    /// Moves the frame by a drag, keeping it on screen.
    func drag(by translation: CGSize) {
        let start = dragStart ?? rect.origin
        dragStart = start
        rect.origin = CGPoint(x: min(max(start.x + translation.width, 0), screen.frame.width - rect.width),
                              y: min(max(start.y + translation.height, 0), screen.frame.height - rect.height))
    }
}

private struct CaptureOverlayView: View {
    @ObservedObject var model: CaptureOverlay

    var body: some View {
        GeometryReader { geo in
            let r = model.rect
            ZStack(alignment: .topLeading) {
                // Dim everything except the frame.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(r)
                }
                .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

                Rectangle()
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(Color.white.opacity(0.001))  // so the whole frame takes the drag
                    .overlay {
                        ForEach(0..<4, id: \.self) { corner in
                            Circle().fill(.white).frame(width: 9, height: 9)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing][corner])
                                .padding(-4.5)
                        }
                    }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { model.drag(by: $0.translation) }
                            .onEnded { _ in model.dragStart = nil }
                    )
                    .pointerStyle(.grabIdle)

                toolbar
                    .fixedSize()
                    .position(x: min(max(r.midX, 180), geo.size.width - 180),
                              y: r.maxY + 44 < geo.size.height ? r.maxY + 32 : max(r.minY - 32, 32))
            }
        }
        .ignoresSafeArea()
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder").foregroundStyle(terracotta)
            Text(model.preset.label).font(.callout.weight(.semibold))
            if !model.preset.name.isEmpty {
                Text("\(Int(model.rect.width)) × \(Int(model.rect.height))").font(.callout).foregroundStyle(.secondary)
            }
            Text("Drag to move").font(.caption).foregroundStyle(.secondary)
            Button("Cancel") { model.cancel() }
                .buttonStyle(.glass).keyboardShortcut(.cancelAction)
            Button("Capture") { model.capture() }
                .buttonStyle(.glassProminent).tint(terracotta).keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}
