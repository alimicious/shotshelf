import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

private let terracotta = Color(nsColor: ShelfIcon.terracotta)

/// Screen recordings (⌘⇧5): a frame for their tile, their length, and saving a trimmed copy or
/// a GIF of them.
enum Recording {
    /// A frame from near the start, for the recording's tile. Blocks, so call off the main thread.
    static func frame(_ url: URL, maxPixels: Int) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.1, preferredTimescale: 600)) { image, _, _ in
            box.image = image
            done.signal()
        }
        done.wait()
        return box.image.map { NSImage(cgImage: $0, size: .zero) }
    }

    static func duration(_ url: URL) async -> Double? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    /// "0:07" or "1:23".
    static func label(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// Saves the part of the recording in `range` as a looping GIF `width` pixels wide at `fps`
    /// frames a second. `progress` gets 0 to 1 as it goes.
    static func gif(from url: URL, range: CMTimeRange, width: Int, fps: Double, to dest: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int(range.duration.seconds * fps))
        let times = (0..<count).map { CMTimeAdd(range.start, CMTime(seconds: Double($0) / fps, preferredTimescale: 600)) }
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var done = 0
        for await result in generator.images(for: times) {
            if let image = try? result.image { CGImageDestinationAddImage(destination, image, frameProperties) }
            done += 1
            progress(Double(done) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Saves the part of the recording in `range` as its own movie, without re-encoding it.
    static func trimmed(from url: URL, range: CMTimeRange, to dest: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.timeRange = range
        try await session.export(to: dest, as: .mov)
    }
}

/// The recording editor: plays the recording, trims it with the system's own trim bar, and saves
/// the trimmed part as a movie or a GIF.
@MainActor
final class RecordingModel: ObservableObject {
    let shot: Shot
    let player: AVPlayer
    weak var playerView: AVPlayerView?
    @Published var gifWidth = 720
    @Published var trimmed = false
    /// What it's busy saving, with progress, while a save is under way.
    @Published var busy: String?

    static let gifWidths = [480, 720, 1080]

    init(shot: Shot) {
        self.shot = shot
        player = AVPlayer(url: shot.url)
    }

    /// The whole recording, or the part the trim bar kept.
    var range: CMTimeRange {
        let item = player.currentItem
        let duration = item?.duration.isNumeric == true ? item!.duration : .zero
        var start = item?.reversePlaybackEndTime ?? .invalid
        var end = item?.forwardPlaybackEndTime ?? .invalid
        if !start.isNumeric { start = .zero }
        if !end.isNumeric { end = duration }
        return CMTimeRange(start: start, end: end)
    }

    func trim() {
        guard let view = playerView, view.canBeginTrimming else { return }
        player.pause()
        view.beginTrimming { [weak self] result in
            MainActor.assumeIsolated { if result == .okButton { self?.trimmed = true } }
        }
    }
}

struct RecordingView: View {
    @ObservedObject var model: RecordingModel
    let onSaveGIF: () -> Void
    let onSaveVideo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .padding(16)
            HStack(spacing: 10) {
                Button { model.trim() } label: { Label(model.trimmed ? "Trim Again" : "Trim", systemImage: "timeline.selection") }
                    .buttonStyle(.glass)
                    .help("Drag the yellow handles to keep just part of the recording")
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(Recording.label(model.range.duration.seconds) + (model.trimmed ? " after trimming" : ""))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Picker("GIF width", selection: $model.gifWidth) {
                    ForEach(RecordingModel.gifWidths, id: \.self) { Text("\($0) px").tag($0) }
                }
                .fixedSize()
                .help("How wide the GIF is. Smaller ones are much smaller files.")
                Button("Save Trimmed Video", action: onSaveVideo)
                    .buttonStyle(.glass).disabled(!model.trimmed || model.busy != nil)
                Button("Save GIF", action: onSaveGIF)
                    .buttonStyle(.glassProminent).tint(terracotta).disabled(model.busy != nil)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// The system player, with its trim bar, inside the editor.
private struct PlayerView: NSViewRepresentable {
    let model: RecordingModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        model.playerView = view
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
