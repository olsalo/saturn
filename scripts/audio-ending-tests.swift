import Foundation
import AVFoundation
import CryptoKit

@main struct AudioEndingTests {
    static func videoDigests(_ url: URL) async throws -> [SHA256.Digest] {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var hashes: [SHA256.Digest] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.dataBuffer else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(buffer))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            precondition(status == kCMBlockBufferNoErr)
            hashes.append(SHA256.hash(data: bytes))
        }
        precondition(reader.status == .completed)
        return hashes
    }

    static func main() async throws {
        let fractionalEnd = CMTime(value: 31, timescale: 30)
        precondition(!exceedsVideoEnd(CMTime(value: 620, timescale: 600), videoEnd: fractionalEnd))
        precondition(!exceedsVideoEnd(CMTime(value: 621, timescale: 600), videoEnd: fractionalEnd), "A single movie-timescale tick must not reject an export")
        precondition(exceedsVideoEnd(CMTime(value: 622, timescale: 600), videoEnd: fractionalEnd), "A larger audio-only tail must still be rejected")
        precondition(!needsExportAlignment(fractionalEnd, videoEnd: fractionalEnd))
        precondition(needsExportAlignment(fractionalEnd + CMTime(value: 1, timescale: 1000), videoEnd: fractionalEnd), "A one-millisecond audio tail must be trimmed")
        if CommandLine.arguments.contains("--timing-only") {
            print("MP4 timing tolerance regression passed.")
            return
        }
        if CommandLine.arguments.contains("--check-small-tail") {
            let input = URL(fileURLWithPath: CommandLine.arguments[1])
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("saturn-small-tail-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let copy = folder.appendingPathComponent("copy.mp4")
            try FileManager.default.copyItem(at: input, to: copy)
            let beforeAsset = AVURLAsset(url: copy)
            let beforeVideo = try await beforeAsset.loadTracks(withMediaType: .video).first!
            let beforeEnd = CMTimeRangeGetEnd(try await beforeVideo.load(.timeRange))
            let beforeDuration = try await beforeAsset.load(.duration)
            precondition(needsExportAlignment(beforeDuration, videoEnd: beforeEnd) && !exceedsVideoEnd(beforeDuration, videoEnd: beforeEnd), "Fixture must have a sub-tick overrun")
            let before = try await videoDigests(copy)
            try await alignExportAudioToVideo(url: copy, cancel: folder.appendingPathComponent("cancel"))
            let afterAsset = AVURLAsset(url: copy)
            let afterVideo = try await afterAsset.loadTracks(withMediaType: .video).first!
            let afterEnd = CMTimeRangeGetEnd(try await afterVideo.load(.timeRange))
            let afterDuration = try await afterAsset.load(.duration)
            precondition(!needsExportAlignment(afterDuration, videoEnd: afterEnd), "Container still extends past video")
            for audio in try await afterAsset.loadTracks(withMediaType: .audio) {
                let audioEnd = CMTimeRangeGetEnd(try await audio.load(.timeRange))
                precondition(!needsExportAlignment(audioEnd, videoEnd: afterEnd), "Audio still extends past video")
            }
            let after = try await videoDigests(copy)
            precondition(!before.isEmpty && before == after, "Timing correction changed encoded video samples")
            print("Sub-tick audio tail regression passed; encoded video samples are unchanged.")
            return
        }
        let source = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let video = try await source.loadTracks(withMediaType: .video).first!
        let audio = try await source.loadTracks(withMediaType: .audio).first!
        let end = CMTimeRangeGetEnd(try await video.load(.timeRange))
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, end: end - CMTime(value: 1, timescale: 30)), of: video, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(try await audio.load(.timeRange), of: audio, at: .zero)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        let url = folder.appendingPathComponent("audio-tail-regression.mp4")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: url, as: .mp4)
        do {
            try await validateVideoEnding(asset: AVURLAsset(url: url))
            fatalError("Accepted an audio-only ending")
        } catch {
            precondition(error.localizedDescription.contains("beyond its final video frame"), error.localizedDescription)
        }
        let before = try await videoDigests(url)
        try await alignExportAudioToVideo(url: url, cancel: folder.appendingPathComponent("cancel-export"))
        try await validateVideoEnding(asset: AVURLAsset(url: url))
        let after = try await videoDigests(url)
        precondition(!before.isEmpty && before == after, "Timing correction changed encoded video samples")
        print("Audio ending regression passed: audio-only ending rejected, presentation trimmed to video end, final frame decodes, all encoded video samples unchanged.")
    }
}
