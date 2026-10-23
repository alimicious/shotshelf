import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// ShotShelf's mark: a soft orange orb whose colours drift slowly into one another, with a fine
/// film grain and a little depth, like warm light through frosted glass. It holds still with
/// Reduce Motion, and whenever `animated` is off (so it never ticks in a closed panel).
struct GradientOrb: View {
    var animated = true
    /// Freezes it at this moment instead, for `--render-orb`.
    var time: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cream = Color(red: 1.0, green: 0.88, blue: 0.68)
    private static let peach = Color(red: 0.98, green: 0.72, blue: 0.48)
    private static let orange = Color(red: 0.94, green: 0.5, blue: 0.26)
    private static let ember = Color(red: 0.89, green: 0.37, blue: 0.17)
    private static let rust = Color(red: 0.72, green: 0.25, blue: 0.11)
    private static let umber = Color(red: 0.5, green: 0.14, blue: 0.07)

    /// Light peach at the top left, a band of cream across the middle, hot orange to the right and
    /// deep rust low on the left, in a 4 × 4 grid.
    private static let colors: [Color] = [
        cream, peach, orange, rust,
        peach, cream, orange, ember,
        rust, orange, cream, orange,
        umber, ember, orange, peach,
    ]

    var body: some View {
        if let time {
            orb(at: time)
        } else if animated && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                orb(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            orb(at: 0)
        }
    }

    private func orb(at t: Double) -> some View {
        MeshGradient(width: 4, height: 4, points: Self.points(at: t), colors: Self.colors, smoothsColors: true)
            .overlay {
                if let grain = OrbGrain.image {
                    Image(decorative: grain, scale: 2).resizable(resizingMode: .tile)
                        .blendMode(.overlay).opacity(0.2)
                }
            }
            // Depth: a glow towards the upper left, shade towards the rim at the lower right.
            .overlay {
                EllipticalGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.16)],
                                   center: UnitPoint(x: 0.34, y: 0.3), startRadiusFraction: 0, endRadiusFraction: 0.82)
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
    }

    /// The mesh's points wander on slow, out-of-step loops (10 to 20 seconds each); the corners
    /// stay put and the edge points slide along their edges, so the circle is always filled.
    private static func points(at t: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double) -> Float { Float(sin(t * speed + phase) * 0.12) }
        let a: Float = 1 / 3, b: Float = 2 / 3
        return [
            [0, 0], [a + wave(0.41, 0), 0], [b + wave(0.35, 1), 0], [1, 0],
            [0, a + wave(0.33, 2)], [a + wave(0.52, 3), a + wave(0.44, 4)], [b + wave(0.38, 5), a + wave(0.57, 6)], [1, a + wave(0.47, 7)],
            [0, b + wave(0.39, 8)], [a + wave(0.45, 9), b + wave(0.36, 10)], [b + wave(0.55, 11), b + wave(0.42, 12)], [1, b + wave(0.31, 13)],
            [0, 1], [a + wave(0.37, 14), 1], [b + wave(0.49, 15), 1], [1, 1],
        ]
    }
}

/// Grey speckle, made once and tiled over the orb for its grain.
private enum OrbGrain {
    static let image: CGImage? = {
        let noise = CIFilter.randomGenerator().outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        // One channel copied into all three, so the grain has no colour of its own.
        let channel = CIVector(x: 1, y: 0, z: 0, w: 0)
        guard let grey = noise?.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": channel, "inputGVector": channel, "inputBVector": channel,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]) else { return nil }
        return CIContext().createCGImage(grey, from: grey.extent)
    }()
}

/// The orb with the polaroid cut out of it, so whatever's behind (the glass, the page) shows
/// through the polaroid's shape. Small ones get a bigger polaroid so the cut stays legible.
struct OrbMark: View {
    let size: CGFloat
    var animated = true
    var time: Double?

    var body: some View {
        GradientOrb(animated: animated, time: time)
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.8, green: 0.36, blue: 0.22).opacity(0.3), radius: size * 0.12, y: size * 0.05)
            // Cut after the glow, so none of it shows inside the polaroid; the mask reaches past the
            // orb's frame to keep the glow around the outside.
            .mask {
                Rectangle()
                    .padding(-size * 0.5)
                    .overlay {
                        Image(nsImage: ShelfIcon.image(size: size * (size >= 64 ? 0.42 : 0.56))).renderingMode(.template)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
    }
}
