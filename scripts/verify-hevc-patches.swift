import Foundation
import AVFoundation

/// Compare a compositor master with its HEVC output at export resolution. Compression may
/// soften edges, but white source regions must not become flashing black blocks.
@main struct VerifyHEVCPatches {
    static func output(_ path: String, size: CGSize) async throws -> (AVAssetReader, AVAssetReaderOutput) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let natural = try await track.load(.naturalSize)
        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if natural == size {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        } else {
            let scaled = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
            let composition = AVMutableVideoComposition()
            composition.renderSize = size
            composition.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = try await track.load(.timeRange)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(CGAffineTransform(scaleX: size.width / natural.width, y: size.height / natural.height), at: .zero)
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]
            scaled.videoComposition = composition
            output = scaled
        }
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        return (reader, output)
    }
    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let tolerance = max(1, Int(16 * size.width * size.height / (3456 * 2160)))
        let (referenceReader, reference) = try await output(CommandLine.arguments[1], size: size)
        let (encodedReader, encoded) = try await output(CommandLine.arguments[2], size: size)
        var frames = 0
        var worst = 0
        var squaredError = 0.0
        var components = 0
        var edgeSquaredError = 0.0
        var edgeComponents = 0
        while let original = reference.copyNextSampleBuffer() {
            guard let compressed = encoded.copyNextSampleBuffer(),
                  abs(original.presentationTimeStamp.seconds - compressed.presentationTimeStamp.seconds) < 0.001,
                  let a = original.imageBuffer, let b = compressed.imageBuffer,
                  CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
                  CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else {
                throw error("Reference/output frame alignment changed")
            }
            CVPixelBufferLockBaseAddress(a, .readOnly)
            CVPixelBufferLockBaseAddress(b, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(a, .readOnly)
                CVPixelBufferUnlockBaseAddress(b, .readOnly)
            }
            let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
            let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
            var black = 0
            for y in stride(from: 16, to: CVPixelBufferGetHeight(a) - 16, by: 2) {
                for x in stride(from: 16, to: CVPixelBufferGetWidth(a) - 16, by: 2) {
                    let i = y * sa + x * 4, j = y * sb + x * 4
                    let isEdge = (0..<3).contains { channel in
                        abs(Int(pa[i + channel]) - Int(pa[i + 4 + channel])) > 12 ||
                        abs(Int(pa[i + channel]) - Int(pa[i + sa + channel])) > 12
                    }
                    for channel in 0..<3 {
                        let difference = Double(pa[i + channel]) - Double(pb[j + channel])
                        squaredError += difference * difference
                        components += 1
                        if isEdge {
                            edgeSquaredError += difference * difference
                            edgeComponents += 1
                        }
                    }
                    if min(pa[i], pa[i+1], pa[i+2]) > 230 && max(pb[j], pb[j+1], pb[j+2]) < 80 { black += 1 }
                }
            }
            guard black <= tolerance else { throw error("Introduced black patch at \(original.presentationTimeStamp.seconds)s: \(black) sampled pixels") }
            worst = max(worst, black)
            frames += 1
        }
        guard encoded.copyNextSampleBuffer() == nil, referenceReader.status == .completed,
              encodedReader.status == .completed, frames > 0 else {
            throw error("Incomplete reference/output decode")
        }
        let psnr = 10 * log10(255 * 255 / max(0.000001, squaredError / Double(components)))
        let edgePSNR = 10 * log10(255 * 255 / max(0.000001, edgeSquaredError / Double(max(1, edgeComponents))))
        print("Edge detail: \(String(format: "%.2f", edgePSNR)) dB RGB PSNR.")
        // Also reject broad quantization damage that doesn't produce black blocks.
        guard edgePSNR >= 30 else { throw error("Excessive edge detail loss: \(edgePSNR) dB RGB PSNR (minimum 30)") }
        guard psnr >= 38 else { throw error("Excessive compression loss: \(psnr) dB RGB PSNR (minimum 38)") }
        print("HEVC detail regression passed: \(String(format: "%.2f", psnr)) dB RGB PSNR.")
        print("HEVC patch regression passed: \(frames) aligned frames, worst unexpected black pixel count \(worst).")
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "HEVCPatchTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
