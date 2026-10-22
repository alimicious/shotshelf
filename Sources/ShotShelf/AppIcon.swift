import AppKit

/// The app's Finder/Launchpad icon: two fanned polaroids on a terracotta tile, the front one
/// showing the same sun and hill as the menu bar glyph. build.sh renders it with
/// `ShotShelf --iconset <dir>` and packs it with iconutil, so there's no image file to keep in sync.
enum AppIcon {
    private static let tileTop = NSColor(srgbRed: 0.92, green: 0.57, blue: 0.45, alpha: 1)
    private static let tileBottom = NSColor(srgbRed: 0.76, green: 0.36, blue: 0.24, alpha: 1)
    private static let paper = NSColor(srgbRed: 0.99, green: 0.975, blue: 0.955, alpha: 1)
    private static let skyTop = NSColor(srgbRed: 1, green: 0.92, blue: 0.84, alpha: 1)
    private static let skyBottom = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.66, alpha: 1)
    private static let sun = NSColor(srgbRed: 1, green: 0.78, blue: 0.38, alpha: 1)
    private static let farHill = NSColor(srgbRed: 0.90, green: 0.58, blue: 0.45, alpha: 1)
    private static let nearHill = NSColor(srgbRed: 0.75, green: 0.35, blue: 0.23, alpha: 1)
    private static let darkTop = NSColor(srgbRed: 0.33, green: 0.30, blue: 0.29, alpha: 1)
    private static let darkBottom = NSColor(srgbRed: 0.19, green: 0.17, blue: 0.16, alpha: 1)

    /// Writes the PNG sizes iconutil expects into an .iconset folder.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(pixels: points * scale).write(to: dir.appendingPathComponent(name))
            }
        }
    }

    private static func png(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Follows Apple's icon grid: an 824pt tile centered on a 1024pt canvas, with a soft drop shadow.
    /// Everything else is laid out in those 1024 units and scaled.
    private static func draw(size s: CGFloat) {
        let u = s / 1024
        let tile = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: 100 * u, dy: 100 * u)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

        NSGraphicsContext.saveGraphicsState()
        shadow(y: -10 * u, blur: 20 * u, alpha: 0.3).set()
        tileBottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: tileTop, ending: tileBottom)!.draw(in: path, angle: -90)
        // A soft sheen across the top, like light on glass.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: NSColor(white: 1, alpha: 0.22), ending: NSColor(white: 1, alpha: 0))!
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let card = NSSize(width: 380 * u, height: 450 * u)
        polaroid(center: NSPoint(x: 452 * u, y: 548 * u), size: card, degrees: 11, u: u) { photo in
            NSGradient(starting: darkTop, ending: darkBottom)!.draw(in: photo, angle: -90)
        }
        polaroid(center: NSPoint(x: 566 * u, y: 470 * u), size: card, degrees: -7, u: u) { photo in
            landscape(in: photo)
        }
    }

    /// A white instant-photo card, rotated about its centre, with `content` drawn into its photo area.
    private static func polaroid(center: NSPoint, size: NSSize, degrees: CGFloat, u: CGFloat, content: (NSRect) -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: degrees)
        transform.concat()

        let card = NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        shadow(y: -14 * u, blur: 30 * u, alpha: 0.28).set()
        paper.setFill()
        NSBezierPath(roundedRect: card, xRadius: 16 * u, yRadius: 16 * u).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Even borders on three sides and the classic thick chin at the bottom.
        let border = 26 * u
        let photo = NSRect(x: card.minX + border, y: card.minY + 104 * u,
                           width: card.width - border * 2, height: card.height - border - 104 * u)
        let photoPath = NSBezierPath(roundedRect: photo, xRadius: 6 * u, yRadius: 6 * u)
        NSGraphicsContext.saveGraphicsState()
        photoPath.addClip()
        content(photo)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.08).setStroke()
        photoPath.lineWidth = 2 * u
        photoPath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The menu bar glyph's scene in colour: a warm sky, a sun, and two rolling hills.
    private static func landscape(in r: NSRect) {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        NSGradient(starting: skyTop, ending: skyBottom)!.draw(in: r, angle: -90)

        sun.setFill()
        let radius = r.width * 0.12
        NSBezierPath(ovalIn: NSRect(x: p(0.72, 0).x - radius, y: p(0, 0.74).y - radius, width: radius * 2, height: radius * 2)).fill()

        let far = NSBezierPath()
        far.move(to: p(0, 0.30))
        far.curve(to: p(0.62, 0.52), controlPoint1: p(0.25, 0.42), controlPoint2: p(0.45, 0.52))
        far.curve(to: p(1, 0.34), controlPoint1: p(0.80, 0.52), controlPoint2: p(0.92, 0.40))
        far.line(to: p(1, 0))
        far.line(to: p(0, 0))
        far.close()
        farHill.setFill()
        far.fill()

        let near = NSBezierPath()
        near.move(to: p(0, 0.22))
        near.curve(to: p(0.36, 0.48), controlPoint1: p(0.12, 0.38), controlPoint2: p(0.24, 0.48))
        near.curve(to: p(1, 0.12), controlPoint1: p(0.52, 0.48), controlPoint2: p(0.78, 0.14))
        near.line(to: p(1, 0))
        near.line(to: p(0, 0))
        near.close()
        nearHill.setFill()
        near.fill()
    }

    private static func shadow(y: CGFloat, blur: CGFloat, alpha: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: y)
        shadow.shadowBlurRadius = blur
        shadow.shadowColor = NSColor(white: 0, alpha: alpha)
        return shadow
    }
}
