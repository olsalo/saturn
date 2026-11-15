import AppKit
import ScreenCaptureKit
import AVFoundation

/// Opt-in desktop test: records only our own synthetic window, never the desktop.
/// Compare color-managed sRGB pixels, rather than unconverted video RGB bytes.
@main struct CaptureColorTests {
    static let swatches: [[Int]] = [[212, 242, 239], [128, 128, 128], [32, 96, 160],
                                   [200, 80, 120], [255, 255, 255], [16, 16, 16]]
    @MainActor static func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw failure("Color capture test requires existing Screen Recording permission; no access was requested.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saturn-colors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true; window.hasShadow = false; window.level = .floating
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.wantsLayer = true
        var swatchLayers: [CALayer] = []
        for (index, rgb) in swatches.enumerated() {
            let layer = CALayer()
            layer.frame = CGRect(x: index * 100, y: 0, width: 100, height: 300)
            layer.backgroundColor = NSColor(srgbRed: CGFloat(rgb[0]) / 255,
                green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1).cgColor
            view.layer!.addSublayer(layer)
            swatchLayers.append(layer)
        }
        // Keep the marker outside the swatches. The corrected pass ends with
        // several seconds of static screen plus system audio.
        let marker = CALayer()
        marker.backgroundColor = NSColor.black.cgColor
        view.layer!.addSublayer(marker)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw failure("Synthetic color window was not found")
        }
        // Force P3 for the negative control so it reproduces the old display
        // profile mismatch even when the test machine has an sRGB display.
        for corrected in [false, true] {
            let config = SCStreamConfiguration()
            config.width = 600; config.height = 300; config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.capturesAudio = corrected
            if corrected { configureCaptureColors(config) }
            else { config.colorSpaceName = CGColorSpace.displayP3 }
            let url = root.appendingPathComponent(corrected ? "source.mov" : "p3.mov")
            let capture = Capture(cursor: FileHandle.nullDevice)
            capture.video = try CaptureVideoWriter(url: url, width: 600, height: 300)
            let queue = DispatchQueue(label: "saturn.color-test")
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: capture)
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: queue)
            if corrected {
                capture.systemAudio = SeparateAudioWriter(url: root.appendingPathComponent("system.m4a"))
                try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
            var finalSwatches = swatches
            if corrected { finalSwatches[0] = [80, 180, 220] }
            for frame in 0..<(corrected ? 210 : 30) {
                if corrected && frame == 150 {
                    // After a long idle gap, the actual final picture changes.
                    // Holding an earlier frame must fail the ending check.
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    swatchLayers[0].backgroundColor = NSColor(srgbRed: 80.0 / 255,
                        green: 180.0 / 255, blue: 220.0 / 255, alpha: 1).cgColor
                    CATransaction.commit(); CATransaction.flush()
                }
                if frame < 30 {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    marker.frame = CGRect(x: frame * 4, y: 0, width: 2, height: 2)
                    CATransaction.commit(); CATransaction.flush()
                }
                queue.sync { capture.videoTick(at: CMClockGetTime(CMClockGetHostTimeClock())) }
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
            try queue.sync { try capture.video!.stop(at: stopTime) }
            try await stream.stopCapture()
            queue.sync { }
            try await capture.video!.finish()
            try await capture.systemAudio?.finish()
            if let error = capture.captureError() { throw error }
            let errors = try await colorErrors(url)
            if corrected {
                guard errors.max()! <= 3 else { throw failure("Captured color drift: \(errors)") }
                let tailErrors = try await colorErrors(url, at: CMTime(seconds: 6.5, preferredTimescale: 600), expected: finalSwatches)
                guard tailErrors.max()! <= 3 else { throw failure("System-audio idle ending lost its picture: \(tailErrors)") }
                guard capture.systemAudio?.firstTimeUs != nil else { throw failure("System audio did not run during the idle-tail test") }
                print("Capture colors and system-audio idle ending passed: worst sRGB channel error \(errors.max()!), tolerance 3.")
            } else {
                guard errors[0] >= 7 else { throw failure("Negative control did not reproduce the reported color shift: \(errors)") }
                print("P3 negative control reproduced color shift: \(errors[0]) levels for #d4f2ef.")
            }
        }
        let manifest: [String: Any] = [
            "media": ["path": "source.mov", "width": 600, "height": 300,
                      "frameRate": ["numerator": 30, "denominator": 1], "separateAudio": [:]] as [String: Any],
            "appearance": ["background": ["type": "none"], "cornerRadiusPx": 0] as [String: Any],
            "export": ["width": 600, "height": 300, "frameRate": 30]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let output = root.appendingPathComponent("export.mp4")
        try await exportVideo(["workspace": root.path, "output": output.path])
        let errors = try await colorErrors(output)
        // The compositor and second lossy encode add rounding error. Keep the
        // reported pastel within two levels and the full palette within four.
        guard errors[0] <= 2, errors.max()! <= 4 else { throw failure("Exported color drift: \(errors)") }
        var finalSwatches = swatches; finalSwatches[0] = [80, 180, 220]
        let tailErrors = try await colorErrors(output, at: CMTime(seconds: 6.5, preferredTimescale: 600), expected: finalSwatches)
        guard tailErrors.max()! <= 4 else { throw failure("Export lost the actual final picture: \(tailErrors)") }
        print("Export colors and actual final picture passed: reported swatch error \(errors[0]), palette maximum \(errors.max()!).")
    }
    static func colorErrors(_ url: URL, at time: CMTime = .zero, expected: [[Int]] = swatches) async throws -> [Int] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw failure("Could not prepare sRGB color comparison")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return expected.enumerated().map { index, expected in
            let offset = ((h / 2) * w + (index * 2 + 1) * w / 12) * 4
            let actual = (0..<3).map { Int(pixels[offset + $0]) }
            print(url.lastPathComponent, expected, "->", actual)
            return zip(expected, actual).map { abs($0 - $1) }.max()!
        }
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); app.terminate(nil) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        app.run()
    }
}
