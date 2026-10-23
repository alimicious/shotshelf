import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image work done on whole shots: finding private details to redact, spotting near-identical
/// shots, combining several into one, cutting out a subject, and framing a shot on a background.
/// All on-device; slow-ish, so call off the main thread.
enum ShotTools {
    static func cgImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - Private details

    /// Where private details sit in a shot, as fractions of the image (origin top-left): email
    /// addresses, phone numbers, card numbers, IBANs, API keys and tokens, and whatever follows
    /// "password:" and the like. Best effort, since it goes by the text Vision reads.
    static func privateAreas(_ url: URL) -> [CGRect] {
        guard let image = cgImage(url) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction "fixes" keys and codes into words, which would hide them from the patterns.
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var areas: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for range in privateRanges(in: candidate.string) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                // Vision counts y from the bottom; pad a little so nothing peeks out at the edges.
                let pad = box.height * 0.25
                areas.append(CGRect(x: box.minX - pad, y: 1 - box.maxY - pad, width: box.width + pad * 2, height: box.height + pad * 2)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
        }
        return areas
    }

    private static let privatePatterns: [(pattern: String, group: Int)] = [
        (#"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"#, 0),             // Stripe
        (#"\bsk-[A-Za-z0-9_\-]{16,}"#, 0),                                     // OpenAI, Anthropic
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, 0), // GitHub
        (#"\bAKIA[0-9A-Z]{16}\b"#, 0),                                         // AWS
        (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, 0),                              // Slack
        (#"\bAIza[0-9A-Za-z_\-]{30,}"#, 0),                                    // Google
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, 0), // JWT
        // Any long run of letters and digits mixed, like most other keys and tokens.
        (#"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{32,}\b"#, 0),
        (#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#, 0),  // IBAN
        (#"(?i)\b(?:password|passwd|passcode|pin|secret|token|api[ _-]?key)\b\s*[:=]\s*(\S+)"#, 1),
    ]

    /// The parts of one line of text that look private.
    static func privateRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let whole = NSRange(text.startIndex..., in: text)
        let types = NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        if let detector = try? NSDataDetector(types: types) {
            for match in detector.matches(in: text, range: whole)
            where match.resultType == .phoneNumber || match.url?.scheme == "mailto" {
                if let range = Range(match.range, in: text) { ranges.append(range) }
            }
        }
        for (pattern, group) in privatePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: whole) {
                if let range = Range(match.range(at: group), in: text) { ranges.append(range) }
            }
        }
        // Card numbers: 13 to 19 digits, maybe in groups, that pass the Luhn check.
        if let regex = try? NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#) {
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text), luhn(text[range].filter(\.isNumber)) else { continue }
                ranges.append(range)
            }
        }
        // A key can match several patterns; overlapping matches become one.
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func luhn(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard (13...19).contains(values.count) else { return false }
        let sum = values.reversed().enumerated().reduce(0) { total, item in
            let doubled = item.offset % 2 == 1 ? item.element * 2 : item.element
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    // MARK: - Duplicates

    /// How a shot looks, boiled down by Vision, plus its size: two shots count as the same only
    /// when they're the same size and look almost identical.
    struct Fingerprint: Codable {
        let width: Int
        let height: Int
        /// Vision's feature print, as raw 32-bit floats.
        let vector: Data
    }

    static func fingerprint(_ url: URL) -> Fingerprint? {
        guard let image = cgImage(url) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        return Fingerprint(width: image.width, height: image.height, vector: print.data)
    }

    /// Below this distance two prints are near-identical: the same screen, give or take a cursor
    /// or a clock. On test shots a changed clock came out at 0.07 and a changed line of text at
    /// 0.5, so this errs on the side of keeping things (`--fingerprints` prints the distances).
    static let duplicateDistance: Float = 0.1

    static func distance(_ a: Fingerprint, _ b: Fingerprint) -> Float? {
        guard a.width == b.width, a.height == b.height, a.vector.count == b.vector.count else { return nil }
        return a.vector.withUnsafeBytes { pa in
            b.vector.withUnsafeBytes { pb in
                let x = pa.bindMemory(to: Float.self), y = pb.bindMemory(to: Float.self)
                var sum: Float = 0
                for i in 0..<x.count {
                    let d = x[i] - y[i]
                    sum += d * d
                }
                return sum.squareRoot()
            }
        }
    }

    /// Paths of shots that are near-copies of a newer one (or of a pinned one) and so can go.
    /// Pinned shots always stay.
    static func duplicates(_ shots: [(path: String, date: Date, pinned: Bool, print: Fingerprint)]) -> [String] {
        var kept: [Fingerprint] = []
        var extra: [String] = []
        for shot in shots.sorted(by: { $0.date > $1.date }) {
            let copy = kept.contains { (distance($0, shot.print) ?? .infinity) < duplicateDistance }
            if copy && !shot.pinned {
                extra.append(shot.path)
            } else {
                kept.append(shot.print)
            }
        }
        return extra
    }

    // MARK: - Combine

    /// Several shots as one image: side by side at the shortest one's height, or stacked at the
    /// narrowest one's width (so nothing is blown up), on white with a small gap between them.
    static func combine(_ urls: [URL], stacked: Bool) -> Data? {
        let images = urls.compactMap(cgImage)
        guard images.count > 1 else { return nil }
        let common = stacked ? images.map(\.width).min()! : images.map(\.height).min()!
        let sizes = images.map { image -> CGSize in
            let scale = CGFloat(common) / CGFloat(stacked ? image.width : image.height)
            return CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        }
        let gap = max(16, CGFloat(common) * 0.02).rounded()
        let total = (stacked ? sizes.map(\.height) : sizes.map(\.width)).reduce(0, +) + gap * CGFloat(images.count - 1)
        let width = stacked ? CGFloat(common) : total, height = stacked ? total : CGFloat(common)
        guard let ctx = context(width: Int(width), height: Int(height)) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        var offset: CGFloat = 0
        for (image, size) in zip(images, sizes) {
            // Core Graphics counts y from the bottom, so stacked shots go in from the top down.
            let origin = stacked ? CGPoint(x: 0, y: height - offset - size.height) : CGPoint(x: offset, y: 0)
            ctx.draw(image, in: CGRect(origin: origin, size: size))
            offset += (stacked ? size.height : size.width) + gap
        }
        return ctx.makeImage().flatMap(png)
    }

    // MARK: - Subject

    /// The main subject of a shot (a person, a pet, an object in a photo) cut out on a clear
    /// background and cropped to it, or nil when Vision finds none.
    static func subject(_ url: URL) -> Data? {
        guard let image = cgImage(url) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return nil }
        let masked = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(masked, from: masked.extent).flatMap(png)
    }
}

/// The gradients a shot can be framed on for sharing: padded, with rounded corners and a soft
/// shadow, like a product shot.
enum Backdrop: String, CaseIterable, Identifiable {
    case sunset, ocean, lilac, mint, graphite
    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var colors: (NSColor, NSColor) {
        switch self {
        case .sunset: return (NSColor(srgbRed: 0.98, green: 0.72, blue: 0.55, alpha: 1), ShelfIcon.terracotta)
        case .ocean: return (NSColor(srgbRed: 0.45, green: 0.78, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.16, green: 0.38, blue: 0.85, alpha: 1))
        case .lilac: return (NSColor(srgbRed: 0.93, green: 0.7, blue: 0.9, alpha: 1), NSColor(srgbRed: 0.5, green: 0.38, blue: 0.9, alpha: 1))
        case .mint: return (NSColor(srgbRed: 0.7, green: 0.95, blue: 0.82, alpha: 1), NSColor(srgbRed: 0.18, green: 0.62, blue: 0.55, alpha: 1))
        case .graphite: return (NSColor(srgbRed: 0.36, green: 0.37, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        }
    }

    /// The padding, corner radius and shadow blur for a shot this size, in its pixels.
    static func metrics(width: Int, height: Int) -> (padding: CGFloat, radius: CGFloat, shadow: CGFloat) {
        let long = CGFloat(max(width, height))
        return ((long * 0.07).rounded(), max(8, long * 0.012), long * 0.03)
    }

    /// `image` on this gradient, padded, with rounded corners and a soft shadow.
    func frame(_ image: CGImage) -> CGImage? {
        let m = Self.metrics(width: image.width, height: image.height)
        let width = CGFloat(image.width) + m.padding * 2, height = CGFloat(image.height) + m.padding * 2
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1])
        else { return nil }
        // Light from the top left, darker towards the bottom right.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        let card = CGRect(x: m.padding, y: m.padding, width: CGFloat(image.width), height: CGFloat(image.height))
        let path = CGPath(roundedRect: card, cornerWidth: m.radius, cornerHeight: m.radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -m.shadow * 0.4), blur: m.shadow, color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: card)
        return ctx.makeImage()
    }
}
