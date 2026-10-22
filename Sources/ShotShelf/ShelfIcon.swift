import AppKit

/// The menu bar icon, drawn in code so there's no asset to ship. It's a rounded polaroid template
/// glyph, so the menu bar tints it like the system icons (white on a dark bar, black on a light one).
/// When a new screenshot lands it flashes, a blank photo slides up out of the bar, and the picture
/// develops on it.
enum ShelfIcon {
    static let terracotta = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)  // #D97757

    /// One drawing of the polaroid. `flash` fills the photo window (0 to 1), `scene` is how far the
    /// sun and hill have developed (0 to 1), and `offset` moves the card down in points, out through
    /// the bottom of the icon.
    struct Frame: Hashable {
        var flash: CGFloat = 0
        var scene: CGFloat = 1
        var offset: CGFloat = 0

        static let rest = Frame()
    }

    private static var cache: [String: NSImage] = [:]

    static func image(size: CGFloat = 18, frame: Frame = .rest) -> NSImage {
        let key = "\(frame)-\(size)"
        if let cached = cache[key] { return cached }
        let image = polaroid(size: size, frame: frame)
        cache[key] = image
        return image
    }

    private static func polaroid(size: CGFloat, frame f: Frame) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // Laid out on an 18pt grid and scaled, so every size keeps the same proportions.
            let s = size / 18
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x * s, y: (y + f.offset) * s, width: w * s, height: h * s)
            }
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: (y + f.offset) * s) }

            NSColor.black.setFill()

            // The frame: a rounded card with the photo window cut out and a thicker chin below.
            let photo = NSBezierPath(roundedRect: rect(4.25, 3.25, 9.5, 8.25), xRadius: 1.5 * s, yRadius: 1.5 * s)
            let frame = NSBezierPath(roundedRect: rect(2.5, 1.5, 13, 15), xRadius: 3.25 * s, yRadius: 3.25 * s)
            frame.append(photo)
            frame.windingRule = .evenOdd
            frame.fill()

            // Inside the photo: a sun and a soft hill, clipped to the window's rounded corners. The
            // template's alpha is all the menu bar uses, so a faint scene reads as a developing photo.
            NSGraphicsContext.saveGraphicsState()
            photo.addClip()
            NSColor.black.withAlphaComponent(f.scene).setFill()
            NSBezierPath(ovalIn: rect(10.1, 4.6, 2.2, 2.2)).fill()
            let hill = NSBezierPath()
            hill.move(to: point(4, 11.75))
            hill.curve(to: point(8, 7.4), controlPoint1: point(5.6, 9.6), controlPoint2: point(6.7, 7.4))
            hill.curve(to: point(14, 10.2), controlPoint1: point(9.6, 7.4), controlPoint2: point(11.6, 10.2))
            hill.line(to: point(14, 11.75))
            hill.close()
            hill.fill()
            NSGraphicsContext.restoreGraphicsState()

            // The flash fills the window, with a hairline over its edge so no seam shows where it
            // meets the frame.
            if f.flash > 0 {
                NSColor.black.withAlphaComponent(f.flash).set()
                photo.fill()
                photo.lineWidth = 0.75 * s
                photo.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Plays the new-shot animation on the menu bar icon: a camera flash, the flashed card dropping
/// away, a blank photo sliding up out of the bar with a little overshoot, and the picture
/// developing on it. With Reduce Motion the card stays put: the flash fades and the photo develops.
@MainActor
final class IconAnimator: ObservableObject {
    @Published private(set) var frame = ShelfIcon.Frame.rest
    private var task: Task<Void, Never>?

    private static let tick = 1.0 / 30

    /// Every frame with how long it stays up, in seconds.
    static func steps(reduceMotion: Bool) -> [(ShelfIcon.Frame, Double)] {
        let flash = [(ShelfIcon.Frame(flash: 1), 0.12)]
        let develop = [0.08, 0.18, 0.3, 0.44, 0.58, 0.72, 0.86].map { (ShelfIcon.Frame(scene: $0), 0.13) }
        if reduceMotion {
            let fade = [0.6, 0.3].map { (ShelfIcon.Frame(flash: $0, scene: 0), tick * 2) }
            return flash + fade + develop
        }
        let drop = [2.5, 7, 13].map { (ShelfIcon.Frame(flash: 1, offset: $0), tick) }
        let rise = [18.0, 12, 7.5, 4, 1.5, 0, -1, -1.25, -0.75, -0.25, 0].map { (ShelfIcon.Frame(scene: 0, offset: $0), tick) }
        return flash + drop + rise + develop
    }

    func play() {
        task?.cancel()
        let steps = Self.steps(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        task = Task {
            for (frame, seconds) in steps {
                self.frame = frame
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
            }
            frame = .rest
        }
    }
}
