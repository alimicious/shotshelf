import AppKit

/// The menu bar icon, drawn in code so there's no asset to ship. At rest it's a rounded polaroid
/// template glyph, so the menu bar tints it like the system icons (white on a dark bar, black on a
/// light one). When a new screenshot lands, the pixel mascot pops up and snaps a photo in colour.
enum ShelfIcon {
    static let terracotta = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)  // #D97757

    enum Frame: Hashable {
        case polaroid, mascot, holding, flash
    }

    /// Pixel frames: "#" mascot, "w" polaroid frame, "k" photo, "y" camera flash.
    private static let holding = [
        "...........wwwww",
        "...........wkkkw",
        "...........wkkkw",
        "..########.wwwww",
        "..########.wwwww",
        "..#.####.#...#..",
        "..#.####.#...#..",
        "##############..",
        "..########......",
        "..########......",
        "..#.#..#.#......",
        "..#.#..#.#......",
    ]

    private static let sprites: [Frame: [String]] = [
        .mascot: [
            "................",
            "................",
            "................",
            "..########......",
            "..########......",
            "..#.####.#......",
            "..#.####.#......",
            "############....",
            "..########......",
            "..########......",
            "..#.#..#.#......",
            "..#.#..#.#......",
        ],
        .holding: holding,
        .flash: replacing(holding, [0: "..........ywwwww", 1: "...........wyyyw", 2: "...........wyyyw", 5: "..#.####.#...#.y"]),
    ]

    private static let colors: [Character: NSColor] = [
        "#": terracotta,
        "w": .white,
        "k": NSColor(white: 0.25, alpha: 1),
        "y": NSColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1),
    ]

    private static func replacing(_ rows: [String], _ changes: [Int: String]) -> [String] {
        rows.enumerated().map { changes[$0.offset] ?? $0.element }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(size: CGFloat = 18, frame: Frame = .polaroid) -> NSImage {
        let key = "\(frame)-\(size)"
        if let cached = cache[key] { return cached }
        let image = sprites[frame].map { pixelArt($0, size: size) } ?? polaroid(size: size)
        cache[key] = image
        return image
    }

    private static func pixelArt(_ sprite: [String], size: CGFloat) -> NSImage {
        let cols = CGFloat(sprite[0].count), rows = CGFloat(sprite.count)
        let px = size / cols
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let originY = (size - rows * px) / 2
            // One path per colour so anti-aliasing doesn't leave seams between pixels.
            for (char, color) in colors {
                let path = NSBezierPath()
                for (r, line) in sprite.enumerated() {
                    for (c, ch) in line.enumerated() where ch == char {
                        path.appendRect(NSRect(x: CGFloat(c) * px, y: originY + CGFloat(r) * px, width: px, height: px))
                    }
                }
                color.setFill()
                path.fill()
            }
            return true
        }
    }

    private static func polaroid(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // Laid out on an 18pt grid and scaled, so every size keeps the same proportions.
            let s = size / 18
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }

            NSColor.black.setFill()

            // The frame: a rounded card with the photo window cut out and a thicker chin below.
            let photo = NSBezierPath(roundedRect: rect(4.25, 3.25, 9.5, 8.25), xRadius: 1.5 * s, yRadius: 1.5 * s)
            let frame = NSBezierPath(roundedRect: rect(2.5, 1.5, 13, 15), xRadius: 3.25 * s, yRadius: 3.25 * s)
            frame.append(photo)
            frame.windingRule = .evenOdd
            frame.fill()

            // Inside the photo: a sun and a soft hill, clipped to the window's rounded corners.
            NSGraphicsContext.saveGraphicsState()
            photo.addClip()
            NSBezierPath(ovalIn: rect(10.1, 4.6, 2.2, 2.2)).fill()
            let hill = NSBezierPath()
            hill.move(to: point(4, 11.75))
            hill.curve(to: point(8, 7.4), controlPoint1: point(5.6, 9.6), controlPoint2: point(6.7, 7.4))
            hill.curve(to: point(14, 10.2), controlPoint1: point(9.6, 7.4), controlPoint2: point(11.6, 10.2))
            hill.line(to: point(14, 11.75))
            hill.close()
            hill.fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Plays the mascot's photo-snap when a new screenshot lands, then settles back on the polaroid.
@MainActor
final class MascotAnimator: ObservableObject {
    @Published private(set) var frame: ShelfIcon.Frame = .polaroid
    private var task: Task<Void, Never>?

    func celebrate() {
        task?.cancel()
        task = Task {
            let steps: [(ShelfIcon.Frame, Double)] = [
                (.mascot, 0.3), (.holding, 0.35), (.flash, 0.12), (.holding, 0.2), (.flash, 0.12), (.holding, 1.4),
            ]
            for (frame, seconds) in steps {
                self.frame = frame
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
            }
            frame = .polaroid
        }
    }
}
