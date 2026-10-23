import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

struct Shot: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    /// A screen recording rather than a screenshot.
    var isVideo: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true }
}

enum ShotScanner {
    /// Set by `--folder <dir>` so tests run against sample shots instead of your real ones.
    static var testFolder: URL?

    /// Where macOS saves screenshots: the custom location from the Screenshot app's options, else the Desktop.
    static var folder: URL {
        if let testFolder { return testFolder }
        if let path = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Screenshots and screen recordings sitting directly in `folder`, newest first, or nil if the
    /// folder can't be read. Subfolders are left alone, so shots filed away in projects never show
    /// up or get tidied.
    static func scan(_ folder: URL) -> [Shot]? {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentTypeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return nil }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, let type = v.contentType else { return nil }
            let isShot = type.conforms(to: .image) && isScreenshot(url)
            // Recordings may not carry the screenshot tag, so their default name counts too.
            let isRecording = type.conforms(to: .movie) && (isScreenshot(url) || url.lastPathComponent.hasPrefix("Screen Recording"))
            guard isShot || isRecording else { return nil }
            return Shot(url: url, date: v.creationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    /// macOS tags every screenshot with this attribute when it saves one. Going by the tag rather
    /// than the filename means a random image named "Screenshot…" is never trashed by mistake.
    static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// A downscaled copy for the grid; decoding full Retina screenshots would be slow and memory-hungry.
    static func thumbnail(_ url: URL, maxPixels: Int = 900) -> NSImage? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            return Recording.frame(url, maxPixels: maxPixels)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// One line of text found in a screenshot, with where it sits (as fractions of the image).
struct TextLine {
    let text: String
    let height: CGFloat
    let top: CGFloat
}

enum ShotText {
    /// Reads the text in an image on-device with Vision, top to bottom. Slow-ish: call off the main thread.
    static func recognize(_ url: URL) -> [TextLine] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { obs in
                obs.topCandidates(1).first.map {
                    TextLine(text: $0.string, height: obs.boundingBox.height, top: 1 - obs.boundingBox.maxY)
                }
            }
            .sorted { $0.top < $1.top }
    }

    /// A readable file name like "Xcode – Build Failed 20.02", or nil when there's no usable text.
    static func smartName(_ lines: [TextLine], app: String?, date: Date) -> String? {
        // The biggest text is usually the title: a heading, an error, a window name. Text near
        // the top gets a nudge, since that's where titles live.
        let headline = lines
            .filter { $0.text.filter(\.isLetter).count >= 3 && $0.text.count <= 80 }
            .max { score($0) < score($1) }
            .map { clean($0.text) }
        guard let headline, !headline.isEmpty else { return nil }

        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
        let parts = [app, headline].compactMap { $0 }
        let unique = parts.count == 2 && headline.localizedCaseInsensitiveContains(parts[0]) ? [headline] : parts
        return unique.joined(separator: " – ") + " " + time
    }

    /// What QR codes (and other barcodes) in an image say. Much quicker than reading the text.
    static func codes(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }

    /// Links and email addresses in a shot's text, then what its codes say, for its quick actions.
    static func links(text: String, codes: [String]) -> [ShotLink] {
        var links: [ShotLink] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url else { continue }
                if url.scheme == "mailto" {
                    links.append(ShotLink(kind: .email, value: String(url.absoluteString.dropFirst("mailto:".count))))
                } else if ["http", "https"].contains(url.scheme) {
                    links.append(ShotLink(kind: .web, value: url.absoluteString))
                }
            }
        }
        links += codes.map { ShotLink(kind: .code, value: $0) }
        var seen = Set<String>()
        return Array(links.filter { seen.insert($0.value).inserted }.prefix(6))
    }

    private static func score(_ line: TextLine) -> CGFloat {
        line.height * (line.top < 0.4 ? 1.3 : 1)
    }

    /// Strips characters that don't belong in file names and keeps it short, cutting at a word.
    private static func clean(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\t")
        var name = text.components(separatedBy: banned).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.count > 40 {
            name = String(name.prefix(40))
            if let space = name.lastIndex(of: " ") { name = String(name[..<space]) }
        }
        return name.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

/// Something worth acting on in a shot: a link to open, or an email address or a code's text to copy.
struct ShotLink: Hashable, Identifiable {
    enum Kind { case web, email, code }
    let kind: Kind
    let value: String
    var id: String { value }

    /// A QR code that holds a web address opens it, like a link in the text does.
    var url: URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme) else { return nil }
        return url
    }

    var title: String {
        if let url { return (kind == .code ? "Open QR Link " : "Open ") + Self.short(url) }
        switch kind {
        case .email: return "Copy \(value)"
        default: return "Copy QR Code Text"
        }
    }

    var symbol: String {
        switch kind {
        case .web: return "link"
        case .email: return "envelope"
        case .code: return "qrcode"
        }
    }

    /// "example.com/docs/guide" rather than the whole address with its scheme and query.
    private static func short(_ url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        let full = host + path
        return full.count > 36 ? String(full.prefix(35)) + "…" : full
    }
}

extension ShotScanner {
    /// A free spot for `name` in `folder`: "name.png", then "name 2.png" and so on.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// Tags a file the way macOS tags screenshots, so copies we make (like redacted ones) show up on the shelf.
    static func tagAsScreenshot(_ url: URL) {
        guard let value = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
        _ = value.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, value.count, 0, 0) }
    }
}

/// Calls back on the main queue whenever files are added to, removed from or renamed in a folder.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(_ url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
