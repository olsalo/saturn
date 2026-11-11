import Foundation
import AVFoundation
import Darwin

enum ExportEncoder: String {
    case ffmpeg = "ffmpeg"
    case handBrake = "handbrake"
    case videoToolbox = "videotoolbox"

    // Both existing HandBrake backends remain available by explicit selection.
    static let defaultEncoder: ExportEncoder = .ffmpeg
}

private final class EncoderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var percent = 0.0
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text += String(decoding: data, as: UTF8.self)
        if text.count > 32768 { text = String(text.suffix(32768)) }
        if let regex = try? NSRegularExpression(pattern: #"Encoding: task (\d+) of (\d+),\s*([0-9]+(?:\.[0-9]+)?)\s*%"#),
           let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let taskRange = Range(match.range(at: 1), in: text), let task = Double(text[taskRange]),
           let countRange = Range(match.range(at: 2), in: text), let count = Double(text[countRange]), count > 0,
           let range = Range(match.range(at: 3), in: text), let value = Double(text[range]) {
            percent = min(1, max(percent, (task - 1 + value / 100) / count))
        }
    }
    func status() -> (Double, String) {
        lock.lock(); defer { lock.unlock() }; return (percent, String(text.suffix(3000)))
    }
}

func handBrakeExecutable() throws -> URL {
    let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("HandBrakeCLI")
#if arch(arm64)
    let target = "aarch64-apple-darwin"
#else
    let target = "x86_64-apple-darwin"
#endif
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src-tauri/binaries/HandBrakeCLI-" + target)
    guard let url = [sibling, development].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw NSError(domain: "Saturn", code: 1, userInfo: [NSLocalizedDescriptionKey: "The HEVC encoder is missing. Run npm run setup:encoder, then rebuild Saturn."])
    }
    return url
}

func handBrakeArguments(input: URL, output: URL, encoder: ExportEncoder = .videoToolbox) -> [String] {
    if encoder == .videoToolbox {
        // VideoToolbox has its own quality scale (higher is better), and must
        // not receive x265 presets, AQ tuning, or the SIMD workaround.
        // 57 reduced the retained UI regression export by 14.8% versus 65,
        // preserving every tested window-control arc and passing frame checks.
        return ["--input", input.path, "--output", output.path,
         "--preset", "Fast 2160p60 4K HEVC", "--optimize",
         "--encoder", "vt_h265_10bit", "--encoder-profile", "main10",
         "--encoder-preset", "quality", "--quality", "57", "--no-multi-pass",
         "--maxWidth", "4096", "--maxHeight", "4096", "--rate", "30", "--pfr",
         "--crop", "0:0:0:0", "--non-anamorphic",
         "--no-comb-detect", "--no-decomb", "--no-deinterlace", "--no-detelecine",
         "--all-audio", "--aencoder", "ca_aac", "--ab", "128", "--mixdown", "stereo"]
    }
    // Keep the SIMD workaround while protecting small, low-contrast UI outlines.
    // Edge-aware AQ at 8px granularity avoids erasing window-control arcs.
    // The bundled arm64 x265
    // SIMD path produces reproducible black blocks at moving UI edges when
    // decoded by macOS. Disabling SIMD fixes both retained-master regressions;
    // reducing psy-rdoq or disabling DotProd alone did not reliably fix them.
    var options = "strong-intra-smoothing=0:rect=0:aq-mode=4:qg-size=8:rd=4:psy-rd=0.75:psy-rdoq=1.0:rdoq-level=1:rskip=2:ipratio=1.6"
#if arch(arm64)
    options += ":asm=0"
#endif
    // Constant quality gives text and moving UI the bits they need. One pass
    // avoids the old bitrate-analysis pass and its severe file-size constraint.
    return ["--input", input.path, "--output", output.path,
     "--preset", "Fast 2160p60 4K HEVC", "--optimize",
     "--encoder-preset", "faster", "--quality", "18", "--no-multi-pass",
     "--maxWidth", "4096", "--maxHeight", "4096", "--rate", "30", "--pfr",
     "--encopts", options,
     "--crop", "0:0:0:0", "--non-anamorphic",
     "--no-comb-detect", "--no-decomb", "--no-deinterlace", "--no-detelecine",
     "--all-audio", "--aencoder", "ca_aac", "--ab", "128", "--mixdown", "stereo"]
}

func validateExportEncoder(_ encoder: ExportEncoder) throws {
    if encoder == .ffmpeg {
        try validateFFmpegEncoder()
        return
    }
    let executable = try handBrakeExecutable()
    guard encoder == .videoToolbox else { return }
    // HandBrake only advertises VideoToolbox when the hardware is available.
    // Reject it explicitly instead of allowing an unavailable encoder to fall
    // back to a different codec or spending time rendering the ProRes master.
    let process = Process(); process.executableURL = executable
    process.arguments = ["--help"]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    let help = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit(); pipe.fileHandleForReading.closeFile()
    guard process.terminationStatus == 0,
          help.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "vt_h265_10bit" }) else {
        throw encoderError("VideoToolbox HEVC 10-bit encoding is unavailable on this Mac. Select the HandBrake encoder instead.")
    }
}

func encodeHandBrake(input: URL, output: URL, cancel: URL, duration: Double? = nil, encoder: ExportEncoder = .videoToolbox, report: @escaping ([String: Any]) -> Void) async throws {
    if FileManager.default.fileExists(atPath: cancel.path) { throw encoderError("Export cancelled") }
    try validateExportEncoder(encoder)
    let process = Process(); process.executableURL = try handBrakeExecutable()
    process.arguments = handBrakeArguments(input: input, output: output, encoder: encoder)
    if let duration {
        process.arguments! += ["--stop-at", "duration:" + String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), duration)]
    }
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    let log = EncoderLog(); let drained = DispatchGroup()
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    drained.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { drained.leave() }
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            log.append(data)
        }
    }
    var cancelledAt: Date?
    while process.isRunning {
        if FileManager.default.fileExists(atPath: cancel.path) {
            if cancelledAt == nil { cancelledAt = Date(); process.terminate() }
            else if Date().timeIntervalSince(cancelledAt!) > 3 { kill(process.processIdentifier, SIGKILL) }
        }
        report(["type":"progress", "fraction":0.4 + log.status().0 * 0.59])
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    process.waitUntilExit(); drained.wait(); pipe.fileHandleForReading.closeFile()
    if cancelledAt != nil || FileManager.default.fileExists(atPath: cancel.path) { throw encoderError("Export cancelled") }
    guard process.terminationStatus == 0 else { throw encoderError("HEVC encoding failed: " + log.status().1) }
}

private func encoderError(_ message: String) -> NSError {
    NSError(domain: "Saturn", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
