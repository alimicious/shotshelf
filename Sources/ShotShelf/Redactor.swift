import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

private let terracotta = Color(nsColor: ShelfIcon.terracotta)

/// The redact editor: drag boxes over anything private and they're pixelated in a copy of the shot.
@MainActor
final class RedactModel: ObservableObject {
    let shot: Shot
    let image: CGImage
    /// The whole shot pixelated once up front; boxes reveal it, and saving composites it in.
    let pixelated: CGImage
    /// Boxes as fractions of the image, origin top-left.
    @Published var boxes: [CGRect] = []
    @Published var drawing: CGRect?

    var allBoxes: [CGRect] { boxes + (drawing.map { [$0] } ?? []) }
    var aspect: CGFloat { CGFloat(image.width) / CGFloat(image.height) }

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
    }

    /// The shot with every box pixelated, as PNG data.
    func render() -> Data? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)
        for box in boxes {
            // Core Graphics counts y from the bottom.
            let r = CGRect(x: box.minX * CGFloat(w), y: (1 - box.maxY) * CGFloat(h),
                           width: box.width * CGFloat(w), height: box.height * CGFloat(h))
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.draw(pixelated, in: full)
            ctx.restoreGState()
        }
        guard let output = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, output, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

struct RedactView: View {
    @ObservedObject var model: RedactModel
    let onCopy: (Data) -> Void
    let onSave: (Data) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let size = fitted(in: geo.size)
                canvas(size: size)
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(16)
            toolbar
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    private func fitted(in space: CGSize) -> CGSize {
        let width = min(space.width, space.height * model.aspect)
        return CGSize(width: width, height: width / model.aspect)
    }

    private func canvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: model.image, scale: 1).resizable()
            Image(decorative: model.pixelated, scale: 1).resizable()
                .mask(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(model.allBoxes.enumerated()), id: \.offset) { _, box in
                            Rectangle()
                                .frame(width: box.width * size.width, height: box.height * size.height)
                                .offset(x: box.minX * size.width, y: box.minY * size.height)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            ForEach(Array(model.allBoxes.enumerated()), id: \.offset) { _, box in
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(terracotta, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: box.width * size.width, height: box.height * size.height)
                    .offset(x: box.minX * size.width, y: box.minY * size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in model.drawing = box(from: value.startLocation, to: value.location, in: size) }
                .onEnded { value in
                    let box = box(from: value.startLocation, to: value.location, in: size)
                    model.drawing = nil
                    if box.width > 0.004, box.height > 0.004 { model.boxes.append(box) }
                }
        )
        .pointerStyle(.rectSelection)
    }

    private func box(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let x0 = clamp(a.x / size.width), x1 = clamp(b.x / size.width)
        let y0 = clamp(a.y / size.height), y1 = clamp(b.y / size.height)
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").foregroundStyle(terracotta)
            Text(model.boxes.isEmpty ? "Drag over anything private to pixelate it"
                                     : "\(model.boxes.count) area\(model.boxes.count == 1 ? "" : "s") hidden")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Undo") { _ = model.boxes.popLast() }
                .buttonStyle(.glass).disabled(model.boxes.isEmpty)
                .keyboardShortcut("z")
            Button("Copy") { model.render().map(onCopy) }
                .buttonStyle(.glass).disabled(model.boxes.isEmpty)
            Button("Save Copy") { model.render().map(onSave) }
                .buttonStyle(.glassProminent).tint(terracotta).disabled(model.boxes.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
