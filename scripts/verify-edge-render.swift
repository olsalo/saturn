import Foundation
import AVFoundation

/// Scan every encoded frame around both fractional window edges. The fixture
/// has pale window sides and a bright Dawn background, so a dark seam is invalid.
@main struct VerifyEdgeRender {
    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        let size = try await track.load(.naturalSize)
        let rect = exportVideoRect(source: CGSize(width: 640, height: 400),
                                  canvas: size,
                                  paddingPercent: 38, paddingPixels: 64, none: false)
        var frames = 0
        while let sample = output.copyNextSampleBuffer(), let buffer = sample.imageBuffer {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for edge in [rect.minX, rect.maxX] {
                for x in (Int(floor(edge)) - 4)...(Int(ceil(edge)) + 4) {
                    for y in [900, 1080, 1300] {
                        let scaledY = Int(Double(y) * size.height / 2160)
                        let i = scaledY * stride + x * 4
                        guard min(bytes[i], bytes[i + 1], bytes[i + 2]) > 80 else {
                            throw NSError(domain: "EdgeRenderTest", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "Black window seam at frame \(frames), pixel \(x),\(y)"
                            ])
                        }
                    }
                }
            }
            frames += 1
        }
        guard reader.status == .completed, frames == 60 else {
            throw reader.error ?? NSError(domain: "EdgeRenderTest", code: 2)
        }
        print("Window edge regression passed: all \(frames) encoded frames have clean left/right rims.")
    }
}
