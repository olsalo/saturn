import Foundation
import AVFoundation

@main struct RecordingVideoTests {
    static func pixels(red: UInt8, green: UInt8) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 { for x in 0..<64 {
            let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[i] = 0; bytes[i + 1] = green; bytes[i + 2] = red; bytes[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saturn-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.mov")
        let video = try CaptureVideoWriter(url: url, width: 64, height: 48)
        let origin = CMTime(seconds: 1234, preferredTimescale: 1_000_000)
        let first = pixels(red: 230, green: 20), last = pixels(red: 20, green: 230)
        try video.receive(first, at: origin)
        // Only two screen updates in six seconds. Audio/cursor timer ticks
        // continue while the screen is idle, including the entire final 4s.
        for tick in 1..<180 {
            let time = origin + CMTime(value: Int64(tick), timescale: 30)
            if tick == 60 { try video.receive(last, at: time) }
            try video.advance(to: time)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        try video.stop(at: origin + CMTime(seconds: 6, preferredTimescale: 600))
        // A queued callback after stop must not extend the clip.
        try video.receive(first, at: origin + CMTime(seconds: 8, preferredTimescale: 600))
        try video.advance(to: origin + CMTime(seconds: 8, preferredTimescale: 600))
        try await video.finish()
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let duration = try await asset.load(.duration)
        precondition(duration.seconds >= 6 && duration.seconds < 6.04, "Unexpected video duration: \(duration.seconds)")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(audioTracks.isEmpty, "Source video must not depend on an audio track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); precondition(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            precondition(abs(sample.presentationTimeStamp.seconds - Double(count) / 30) < 0.00001, "Video timeline has a hole at sample \(count): \(sample.presentationTimeStamp.seconds), samples=\(sample.numSamples)")
            count += 1
        }
        precondition(reader.status == .completed && count >= 180, "Missing idle/tail frames")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for seconds in [3.0, 4.0, 5.0, 5.9] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            precondition(rgba[1] > 150 && rgba[0] < 80, "Seeking into the idle ending lost the final picture")
        }
        try await validateVideoEnding(asset: asset)
        let range = try await exportVideoTimeRange(asset: asset, track: track)
        precondition(range.duration.seconds >= 6, "Export discarded the idle ending")
        print("Recording video passed: continuous frames, idle tail seeking, export coverage, audio independence and stop boundary.")
    }
}
