import Foundation
import AVFoundation

@main struct ClipsAudioTests {
    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 1, "Clips must share one continuous playback audio track")
        for start in [0.5, 2.5] {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsNonInterleaved:false])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000), duration: CMTime(seconds: 0.3, preferredTimescale: 48000))
            precondition(reader.startReading())
            var energy = 0.0
            var count = 0
            while let sample = output.copyNextSampleBuffer(), let buffer = sample.dataBuffer {
                var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(buffer) / 4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                precondition(status == kCMBlockBufferNoErr)
                for value in values { energy += Double(value * value); count += 1 }
            }
            precondition(reader.status == .completed)
            precondition(count > 0 && sqrt(energy / Double(count)) > 0.02, "Missing audible audio at \(start)s")
        }
        print("Clip audio passed: audible samples before and after the cut in one playback track.")
    }
}
