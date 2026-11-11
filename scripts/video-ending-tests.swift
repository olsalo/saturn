import Foundation
import AVFoundation

@main struct VideoEndingTests {
    static func main() async throws {
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = pixel!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRow(buffer) * 8
        bytes.initialize(repeating: 0, count: count)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        precondition(isBlankVideoFrame(buffer), "Transparent frame was accepted")
        CVPixelBufferLockBaseAddress(buffer, [])
        for y in 0..<8 { for x in 0..<8 { bytes[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        precondition(isBlankVideoFrame(buffer), "Opaque black frame was accepted")
        CVPixelBufferLockBaseAddress(buffer, [])
        // Content in a corner must not be missed by a sparse pixel probe.
        bytes[7 * CVPixelBufferGetBytesPerRow(buffer) + 7 * 4] = 100
        CVPixelBufferUnlockBaseAddress(buffer, [])
        precondition(!isBlankVideoFrame(buffer), "Visible content was discarded")

        let source = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let track = try await source.loadTracks(withMediaType: .video).first!
        let range = try await exportVideoTimeRange(asset: source, track: track)
        precondition(abs(range.duration.seconds - 2) < 0.0001, "Black tail was not trimmed: \(range.duration.seconds)")
        do {
            try await validateVideoEnding(asset: source)
            fatalError("Validation accepted an encoded black ending")
        } catch {
            precondition(error.localizedDescription == "Export ends with a blank frame", error.localizedDescription)
        }
        print("Video ending regression passed: transparent/black pixels rejected, visible corner retained, encoded black tail trimmed and detected.")
    }
}
