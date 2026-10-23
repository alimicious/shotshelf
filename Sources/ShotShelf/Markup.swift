import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

private let terracotta = Color(nsColor: ShelfIcon.terracotta)

/// The markup tools, in toolbar order.
enum MarkTool: String, CaseIterable, Identifiable {
    case arrow, box, highlight, text, redact
    var id: String { rawValue }

    var name: String {
        switch self {
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .redact: return "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .redact: return "eye.slash"
        }
    }
}

/// The colours to mark up with, in fixed sRGB so the saved image matches the editor.
enum MarkColor {
    static let all: [NSColor] = [
        ShelfIcon.terracotta,
        NSColor(srgbRed: 0.96, green: 0.26, blue: 0.21, alpha: 1),  // red
        NSColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1),       // yellow
        NSColor(srgbRed: 0.16, green: 0.5, blue: 1, alpha: 1),      // blue
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),           // white
    ]
}

/// One thing drawn on the shot. Points are fractions of the image, origin top-left: an arrow runs
/// from `start` to `end`, boxes, highlights and redactions fill the rectangle between them, and
/// text starts at `start`.
struct Mark: Identifiable {
    let id = UUID()
    let tool: MarkTool
    var start: CGPoint
    var end: CGPoint
    var color: Int
    var text = ""

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// An arrow's round-capped shaft and solid head, filled separately so they don't cancel out
    /// where they overlap. Shared by the editor and the saved image.
    static func arrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> (shaft: CGPath, head: CGPath) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let size = min(lineWidth * 6, length * 0.6)
        let base = CGPoint(x: end.x - ux * size * 0.8, y: end.y - uy * size * 0.8)
        let back = CGPoint(x: end.x - ux * size, y: end.y - uy * size)
        let half = size * 0.6

        let line = CGMutablePath()
        line.move(to: start)
        line.addLine(to: base)
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: back.x - uy * half, y: back.y + ux * half))
        head.addLine(to: base)
        head.addLine(to: CGPoint(x: back.x + uy * half, y: back.y - ux * half))
        head.closeSubpath()
        return (line.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10), head)
    }
}

/// The markup editor: arrows, boxes, highlights and text, plus redactions that pixelate whatever
/// they cover. Everything is drawn into a copy; the original shot is never changed.
@MainActor
final class MarkupModel: ObservableObject {
    let shot: Shot
    let image: CGImage
    /// The whole shot pixelated once up front; redactions reveal it, and saving composites it in.
    let pixelated: CGImage
    @Published var marks: [Mark] = []
    /// The mark being dragged out right now.
    @Published var drawing: Mark?
    @Published var tool: MarkTool {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: Prefs.markupTool) }
    }
    @Published var color = 0 {
        didSet {
            // Picking a colour while typing recolours that text.
            if let editing, let i = marks.firstIndex(where: { $0.id == editing }) { marks[i].color = color }
        }
    }
    /// The text mark being typed into, if any.
    @Published var editing: UUID?
    /// A gradient to frame the shot on, for sharing. The last one picked is remembered for
    /// Copy with Background.
    @Published var backdrop: Backdrop? {
        didSet { if let backdrop { UserDefaults.standard.set(backdrop.rawValue, forKey: Prefs.markupBackdrop) } }
    }
    /// A line about what Redact Private Info found, shown over the canvas for a few seconds.
    @Published private(set) var notice: String?
    @Published private(set) var findingPrivate = false

    var allMarks: [Mark] { marks + (drawing.map { [$0] } ?? []) }
    var aspect: CGFloat { CGFloat(image.width) / CGFloat(image.height) }
    /// The whole picture's shape, background included.
    var framedAspect: CGFloat {
        guard backdrop != nil else { return aspect }
        let p = Backdrop.metrics(width: image.width, height: image.height).padding
        return (CGFloat(image.width) + p * 2) / (CGFloat(image.height) + p * 2)
    }
    var hasChanges: Bool { !marks.isEmpty || backdrop != nil }
    /// True when all there is are redactions, so a saved copy is called "(redacted)".
    var redactsOnly: Bool { backdrop == nil && marks.allSatisfy { $0.tool == .redact } }
    /// Line width and text size in the image's own pixels, in step with its size so marks look the
    /// same on a small crop and a whole Retina screen.
    var lineWidth: CGFloat { max(3, CGFloat(max(image.width, image.height)) * 0.0035) }
    var fontSize: CGFloat { max(18, CGFloat(max(image.width, image.height)) * 0.022) }

    init?(shot: Shot) {
        guard let source = CGImageSourceCreateWithURL(shot.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let input = CIImage(cgImage: image)
        // Blocks about 1/50 of the long edge: coarse enough that text can't be read back.
        let scale = Double(max(image.width, image.height)) / 50
        let blocks = input.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: input.extent)
        guard let pixelated = CIContext().createCGImage(blocks, from: input.extent) else { return nil }
        self.shot = shot
        self.image = image
        self.pixelated = pixelated
        tool = MarkTool(rawValue: UserDefaults.standard.string(forKey: Prefs.markupTool) ?? "") ?? .arrow
    }

    /// Keeps the mark just dragged out, unless it's too small to have been meant.
    func finishDrawing() {
        guard let mark = drawing else { return }
        drawing = nil
        let big = mark.tool == .arrow
            ? hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) > 0.01
            : mark.rect.width > 0.004 && mark.rect.height > 0.004
        if big { marks.append(mark) }
    }

    func beginText(at point: CGPoint) {
        commitText()
        let mark = Mark(tool: .text, start: point, end: point, color: color)
        marks.append(mark)
        editing = mark.id
    }

    /// Stops typing; text left empty is dropped.
    func commitText() {
        guard let id = editing else { return }
        editing = nil
        marks.removeAll { $0.id == id && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func text(of id: UUID) -> String {
        marks.first { $0.id == id }?.text ?? ""
    }

    func setText(_ text: String, of id: UUID) {
        if let i = marks.firstIndex(where: { $0.id == id }) { marks[i].text = text }
    }

    func undo() {
        commitText()
        _ = marks.popLast()
    }

    /// Finds email addresses, phone and card numbers, keys, tokens and passwords in the shot's text
    /// and adds a redaction over each one that isn't covered yet.
    func redactPrivateInfo() {
        guard !findingPrivate else { return }
        commitText()
        findingPrivate = true
        // Stays up until it's done: the first search after a restart can take a while.
        notice = "Looking for private details…"
        let url = shot.url
        Task {
            let areas = await Task.detached(operation: { ShotTools.privateAreas(url) }).value
            findingPrivate = false
            let covered = marks.filter { $0.tool == .redact }.map(\.rect)
            let new = areas.filter { area in !covered.contains { $0.contains(area) } }
            marks += new.map { Mark(tool: .redact, start: $0.origin, end: CGPoint(x: $0.maxX, y: $0.maxY), color: 0) }
            show(new.isEmpty ? "Found nothing private to hide"
                             : "Hid \(new.count) private detail\(new.count == 1 ? "" : "s"). Check the rest before sharing.")
        }
    }

    private func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }

    /// The shot with every mark drawn in, as PNG data.
    func render() -> Data? {
        let w = image.width, h = image.height
        let W = CGFloat(w), H = CGFloat(h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)
        for mark in marks where mark.tool == .redact {
            // Core Graphics counts y from the bottom.
            let box = mark.rect
            let r = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.draw(pixelated, in: full)
            ctx.restoreGState()
        }

        // Everything else is drawn top-down, like the editor lays it out.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        let lw = lineWidth
        for mark in marks where mark.tool != .redact {
            let color = MarkColor.all[mark.color]
            let r = CGRect(x: mark.rect.minX * W, y: mark.rect.minY * H, width: mark.rect.width * W, height: mark.rect.height * H)
            ctx.saveGState()
            switch mark.tool {
            case .highlight:
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(color.withAlphaComponent(0.45).cgColor)
                ctx.fill(r)
            case .box:
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(lw)
                let inset = r.insetBy(dx: lw / 2, dy: lw / 2)
                ctx.addPath(CGPath(roundedRect: inset, cornerWidth: lw * 1.5, cornerHeight: lw * 1.5, transform: nil))
                ctx.strokePath()
            case .arrow:
                let arrow = Mark.arrow(from: CGPoint(x: mark.start.x * W, y: mark.start.y * H),
                                       to: CGPoint(x: mark.end.x * W, y: mark.end.y * H), lineWidth: lw)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(arrow.shaft)
                ctx.fillPath()
                ctx.addPath(arrow.head)
                ctx.fillPath()
            case .text:
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
                shadow.shadowBlurRadius = fontSize * 0.16
                NSAttributedString(string: mark.text, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: color,
                    .shadow: shadow,
                ]).draw(at: CGPoint(x: mark.start.x * W, y: mark.start.y * H))
                NSGraphicsContext.restoreGraphicsState()
            case .redact:
                break
            }
            ctx.restoreGState()
        }

        guard let output = ctx.makeImage() else { return nil }
        if let backdrop { return backdrop.frame(output).flatMap(ShotTools.png) }
        return ShotTools.png(output)
    }
}

struct MarkupView: View {
    @ObservedObject var model: MarkupModel
    let onCopy: (Data) -> Void
    let onSave: (Data) -> Void
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let size = fitted(in: geo.size)
                framed(size)
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(16)
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Label(notice, systemImage: model.findingPrivate ? "magnifyingglass" : "eye.slash")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 26)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28, bounce: 0.25), value: model.notice)
            toolbar
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private func fitted(in space: CGSize) -> CGSize {
        let width = min(space.width, space.height * model.framedAspect)
        return CGSize(width: width, height: width / model.framedAspect)
    }

    /// The canvas, on its background when there is one, drawn the way `Backdrop.frame` saves it.
    @ViewBuilder
    private func framed(_ size: CGSize) -> some View {
        if let backdrop = model.backdrop {
            let m = Backdrop.metrics(width: model.image.width, height: model.image.height)
            let scale = size.width / (CGFloat(model.image.width) + m.padding * 2)
            ZStack {
                LinearGradient(colors: [Color(nsColor: backdrop.colors.0), Color(nsColor: backdrop.colors.1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                canvas(size: CGSize(width: CGFloat(model.image.width) * scale, height: CGFloat(model.image.height) * scale))
                    .clipShape(RoundedRectangle(cornerRadius: m.radius * scale))
                    .shadow(color: .black.opacity(0.35), radius: m.shadow * scale / 2, y: m.shadow * scale * 0.4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        } else {
            canvas(size: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }

    private func canvas(size: CGSize) -> some View {
        let scale = size.width / CGFloat(model.image.width)
        return ZStack(alignment: .topLeading) {
            Image(decorative: model.image, scale: 1).resizable()
            Image(decorative: model.pixelated, scale: 1).resizable()
                .mask(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(model.allMarks.filter { $0.tool == .redact }) { mark in
                            Rectangle()
                                .frame(width: mark.rect.width * size.width, height: mark.rect.height * size.height)
                                .offset(x: mark.rect.minX * size.width, y: mark.rect.minY * size.height)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            ForEach(model.allMarks) { mark in
                MarkView(mark: mark, size: size, lineWidth: model.lineWidth * scale, fontSize: model.fontSize * scale)
                    .opacity(mark.id == model.editing ? 0 : 1)
            }
            if let id = model.editing, let mark = model.marks.first(where: { $0.id == id }) {
                textField(for: mark, size: size, fontSize: model.fontSize * scale)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard model.tool != .text else { return }
                    let end = point(value.location, in: size)
                    if model.drawing == nil {
                        model.commitText()
                        model.drawing = Mark(tool: model.tool, start: point(value.startLocation, in: size), end: end, color: model.color)
                    } else {
                        model.drawing?.end = end
                    }
                }
                .onEnded { value in
                    if model.tool == .text {
                        model.beginText(at: point(value.location, in: size))
                    } else {
                        model.finishDrawing()
                    }
                }
        )
        .pointerStyle(model.tool == .text ? .horizontalText : .rectSelection)
    }

    /// Where typing goes for a text mark: a plain field in the text's own size and colour, outlined
    /// while it's being edited.
    private func textField(for mark: Mark, size: CGSize, fontSize: CGFloat) -> some View {
        let x = mark.start.x * size.width, y = mark.start.y * size.height
        return TextField("Text", text: Binding(get: { model.text(of: mark.id) }, set: { model.setText($0, of: mark.id) }))
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(Color(nsColor: MarkColor.all[mark.color]))
            .focused($typing)
            .onSubmit { model.commitText() }
            .onAppear { DispatchQueue.main.async { typing = true } }
            .frame(width: max(60, size.width - x - 8), alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(terracotta, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .padding(-3)
            }
            .offset(x: x, y: y)
    }

    private func point(_ p: CGPoint, in size: CGSize) -> CGPoint {
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return CGPoint(x: clamp(p.x / size.width), y: clamp(p.y / size.height))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(MarkTool.allCases) { tool in toolButton(tool) }
                }
            }
            HStack(spacing: 2) {
                ForEach(MarkColor.all.indices, id: \.self) { i in
                    Button { model.color = i } label: {
                        Circle().fill(Color(nsColor: MarkColor.all[i])).frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().strokeBorder(model.color == i ? Color.primary.opacity(0.75) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            // Redactions are always pixelated, so colour doesn't apply.
            .opacity(model.tool == .redact ? 0.35 : 1)
            .disabled(model.tool == .redact)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 4) {
                    Button { model.redactPrivateInfo() } label: {
                        Image(systemName: "wand.and.sparkles").font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).disabled(model.findingPrivate)
                    .help("Redact Private Info: pixelates email addresses, phone and card numbers, keys, tokens and passwords")
                    Menu {
                        Button { model.backdrop = nil } label: { checked("No Background", model.backdrop == nil) }
                        Divider()
                        ForEach(Backdrop.allCases) { backdrop in
                            Button { model.backdrop = backdrop } label: { checked(backdrop.name, model.backdrop == backdrop) }
                        }
                    } label: {
                        Image(systemName: "photo.artframe").font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
                    }
                    .menuStyle(.button).buttonStyle(.glass).buttonBorderShape(.circle).menuIndicator(.hidden).fixedSize()
                    .help("Background: frame the shot on a gradient, for sharing")
                }
            }
            Spacer()
            Button("Undo") { model.undo() }
                .buttonStyle(.glass).disabled(model.marks.isEmpty)
                .keyboardShortcut(model.editing == nil ? KeyboardShortcut("z") : nil)
            Button("Copy") {
                model.commitText()
                model.render().map(onCopy)
            }
            .buttonStyle(.glass).disabled(!model.hasChanges)
            Button("Save Copy") {
                model.commitText()
                model.render().map(onSave)
            }
            .buttonStyle(.glassProminent).tint(terracotta).disabled(!model.hasChanges)
            // While typing, Return finishes the text instead.
            .keyboardShortcut(model.editing == nil ? .defaultAction : nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder
    private func toolButton(_ tool: MarkTool) -> some View {
        let label = Image(systemName: tool.symbol).font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
        let pick = {
            model.commitText()
            model.tool = tool
        }
        if model.tool == tool {
            Button(action: pick) { label }
                .buttonStyle(.glassProminent).tint(terracotta).buttonBorderShape(.circle).help(tool.name)
        } else {
            Button(action: pick) { label }
                .buttonStyle(.glass).buttonBorderShape(.circle).help(tool.name)
        }
    }
}

/// One mark as the editor shows it, drawn the same way `MarkupModel.render` draws it into the
/// saved image. Redactions just get a dashed outline here; the pixelation is masked in below.
private struct MarkView: View {
    let mark: Mark
    let size: CGSize
    let lineWidth: CGFloat
    let fontSize: CGFloat

    var body: some View {
        let color = Color(nsColor: MarkColor.all[mark.color])
        let r = CGRect(x: mark.rect.minX * size.width, y: mark.rect.minY * size.height,
                       width: mark.rect.width * size.width, height: mark.rect.height * size.height)
        switch mark.tool {
        case .redact:
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(terracotta, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        case .box:
            RoundedRectangle(cornerRadius: lineWidth * 1.5)
                .strokeBorder(color, lineWidth: lineWidth)
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        case .highlight:
            Rectangle().fill(color.opacity(0.45)).blendMode(.multiply)
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        case .arrow:
            let arrow = Mark.arrow(from: CGPoint(x: mark.start.x * size.width, y: mark.start.y * size.height),
                                   to: CGPoint(x: mark.end.x * size.width, y: mark.end.y * size.height), lineWidth: lineWidth)
            ZStack(alignment: .topLeading) {
                Path(arrow.shaft).fill(color)
                Path(arrow.head).fill(color)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        case .text:
            Text(mark.text).font(.system(size: fontSize, weight: .bold)).foregroundStyle(color)
                .shadow(color: .black.opacity(0.45), radius: fontSize * 0.08)
                .fixedSize()
                .offset(x: mark.start.x * size.width, y: mark.start.y * size.height)
        }
    }
}
