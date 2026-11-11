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
