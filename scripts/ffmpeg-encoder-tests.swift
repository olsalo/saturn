import Foundation
import AVFoundation

@main struct FFmpegEncoderTests {
    static func main() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("saturn-ffmpeg-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = folder.appendingPathComponent("existing.mp4")
        let cancel = folder.appendingPathComponent("cancel")
        let sentinel = Data("existing successful export".utf8)
        let encoded = folder.appendingPathComponent("encoded.mp4")
        try await encodeVideo(input: input, output: encoded, cancel: cancel, duration: 2) { _ in }
        let asset = AVURLAsset(url: encoded)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let compressed = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(compressed)
        precondition(reader.startReading())
        var frames = 0, keyframes = 0
        while let sample = compressed.copyNextSampleBuffer() {
            // AVFoundation can expose empty timing markers for reordered video.
            // They are not encoded pictures or independently decodable keyframes.
            guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            frames += 1
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true { keyframes += 1 }
        }
        precondition(reader.status == .completed && frames == 60 && keyframes <= 2,
                     "Unexpected keyframe frequency: \(keyframes) keyframes in \(frames) frames")
        print("FFmpeg compression passed: \(keyframes) keyframes in the two-second fixture (old default inserted five).")
        try sentinel.write(to: output)
        do {
            try await encodeVideo(input: input, output: output, cancel: cancel) { _ in }
            fatalError("FFmpeg overwrote an existing export")
        } catch {
            precondition(error.localizedDescription.contains("FFmpeg HEVC encoding failed"), error.localizedDescription)
            let retained = try Data(contentsOf: output)
            precondition(retained == sentinel)
        }
        do {
            try await encodeVideo(input: folder.appendingPathComponent("missing.mov"),
                                  output: folder.appendingPathComponent("failed.mp4"), cancel: cancel) { _ in }
            fatalError("FFmpeg accepted a missing source")
        } catch {
            precondition(error.localizedDescription.contains("FFmpeg HEVC encoding failed"), error.localizedDescription)
        }
        try Data().write(to: cancel)
        do {
            try await encodeVideo(input: input, output: folder.appendingPathComponent("cancelled.mp4"), cancel: cancel) { _ in }
            fatalError("FFmpeg accepted a pre-cancelled export")
        } catch {
            precondition(error.localizedDescription == "Export cancelled", error.localizedDescription)
            precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancelled.mp4").path))
        }
        print("FFmpeg failures, existing-output protection and pre-launch cancellation passed.")
    }
}
