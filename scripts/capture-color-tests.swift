import AppKit
import ScreenCaptureKit
import AVFoundation

private final class ColorRecording: NSObject, SCRecordingOutputDelegate {
    private let lock = NSLock()
    private var finished = false
    private var error: Error?
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        lock.lock(); finished = true; lock.unlock()
    }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); self.error = error; finished = true; lock.unlock()
    }
    func status() -> (Bool, Error?) {
        lock.lock(); defer { lock.unlock() }; return (finished, error)
    }
}

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
        for (index, rgb) in swatches.enumerated() {
            let layer = CALayer()
            layer.frame = CGRect(x: index * 100, y: 0, width: 100, height: 300)
            layer.backgroundColor = NSColor(srgbRed: CGFloat(rgb[0]) / 255,
                green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1).cgColor
            view.layer!.addSublayer(layer)
        }
        // ScreenCaptureKit omits unchanged frames. Keep a tiny marker moving
        // outside the sample regions so the export has a real video timeline.
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
            if corrected { configureCaptureColors(config) }
            else { config.colorSpaceName = CGColorSpace.displayP3 }
            let url = root.appendingPathComponent(corrected ? "source.mov" : "p3.mov")
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = url; recordingConfig.outputFileType = .mov
            recordingConfig.videoCodecType = .h264
            let delegate = ColorRecording()
            let output = SCRecordingOutput(configuration: recordingConfig, delegate: delegate)
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            for frame in 0..<30 {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                marker.frame = CGRect(x: frame * 4, y: 0, width: 2, height: 2)
                CATransaction.commit(); CATransaction.flush()
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            try await stream.stopCapture()
            for _ in 0..<100 {
                if delegate.status().0 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let status = delegate.status()
            if let error = status.1 { throw error }
            guard status.0 else { throw failure("Color capture finalization timed out") }
            let errors = try await colorErrors(url)
            if corrected {
                guard errors.max()! <= 3 else { throw failure("Captured color drift: \(errors)") }
                print("Capture colors passed: worst sRGB channel error \(errors.max()!), tolerance 3.")
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
        print("Export colors passed: reported swatch error \(errors[0]), palette maximum \(errors.max()!).")
    }
    static func colorErrors(_ url: URL) async throws -> [Int] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let image = try await generator.image(at: .zero).image
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw failure("Could not prepare sRGB color comparison")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return swatches.enumerated().map { index, expected in
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
