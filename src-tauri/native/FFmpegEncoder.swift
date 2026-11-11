import Foundation
import Darwin

func ffmpegExecutable() throws -> URL {
    let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ffmpeg")
#if arch(arm64)
    let target = "aarch64-apple-darwin"
#else
    let target = "x86_64-apple-darwin"
#endif
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src-tauri/binaries/ffmpeg-" + target)
    guard let url = [sibling, development].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw ffmpegError("FFmpeg is missing. Run npm run setup:encoder, then rebuild Saturn.")
    }
    return url
}

private let ffmpegVideoOptions = [
    "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le",
    "-q:v", "57", "-allow_sw", "0", "-realtime", "0", "-prio_speed", "0",
    // Match HandBrake's ~10-second GOP at the 30fps export ceiling and allow
    // frame reordering. FFmpeg's 12-frame default inflates static UI recordings.
    "-g", "301", "-bf", "2",
]

func ffmpegArguments(input: URL, output: URL, duration: Double?) -> [String] {
    var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-n",
                "-progress", "pipe:1", "-i", input.path,
                "-map", "0:v:0", "-map", "0:a?",
                "-vf", "fps=fps='min(source_fps,30)'",
                // Constrained VBR retains the 128k target without padding silence.
                "-tag:v", "hvc1", "-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", "128k", "-ac", "2",
                "-movflags", "+faststart"] + ffmpegVideoOptions
    if let duration {
        args += ["-t", String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), duration)]
    }
    return args + [output.path]
}

func validateFFmpegEncoder() throws {
    // Exercise the actual hardware, not just the list of compiled-in encoders.
    // Fail before the expensive ProRes compositor pass on unsupported machines.
    let process = Process()
    process.executableURL = try ffmpegExecutable()
    process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error",
                         "-f", "lavfi", "-i", "color=size=64x64:rate=30",
                         "-frames:v", "1", "-an"] + ffmpegVideoOptions + ["-f", "null", "-"]
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit(); pipe.fileHandleForReading.closeFile()
    guard process.terminationStatus == 0 else {
        throw ffmpegError("FFmpeg hardware HEVC 10-bit encoding is unavailable on this Mac. " + String(message.suffix(3000)))
    }
}

private final class FFmpegLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var seconds = 0.0
    private var completed = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text += String(decoding: data, as: UTF8.self)
        if text.count > 32768 { text = String(text.suffix(32768)) }
        // Only parse complete lines: a progress update may span pipe reads.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if line == "progress=end" { completed = true }
            if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)) {
                seconds = max(seconds, value / 1_000_000)
            }
        }
    }
    func status(duration: Double?) -> (Double, String, Bool) {
        lock.lock(); defer { lock.unlock() }
        let fraction = duration.map { $0 > 0 ? min(1, seconds / $0) : 0 } ?? 0
        return (fraction, String(text.suffix(3000)), completed)
    }
}

func encodeVideo(input: URL, output: URL, cancel: URL, duration: Double? = nil,
                 encoder: ExportEncoder = .defaultEncoder, report: @escaping ([String: Any]) -> Void) async throws {
    if encoder != .ffmpeg {
        try await encodeHandBrake(input: input, output: output, cancel: cancel, duration: duration, encoder: encoder, report: report)
        return
    }
    if FileManager.default.fileExists(atPath: cancel.path) { throw ffmpegError("Export cancelled") }
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw ffmpegError("FFmpeg HEVC encoding failed: the output file already exists.")
    }
    let process = Process()
    process.executableURL = try ffmpegExecutable()
    process.arguments = ffmpegArguments(input: input, output: output, duration: duration)
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    let log = FFmpegLog(); let drained = DispatchGroup()
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
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit(); drained.wait(); pipe.fileHandleForReading.closeFile()
    }
    var cancelledAt: Date?
    while process.isRunning {
        if Task.isCancelled { throw ffmpegError("Export cancelled") }
        if FileManager.default.fileExists(atPath: cancel.path) {
            if cancelledAt == nil { cancelledAt = Date(); process.terminate() }
            else if Date().timeIntervalSince(cancelledAt!) > 3 { kill(process.processIdentifier, SIGKILL) }
        }
        report(["type": "progress", "fraction": 0.4 + log.status(duration: duration).0 * 0.59])
        do { try await Task.sleep(nanoseconds: 100_000_000) }
        catch { throw ffmpegError("Export cancelled") }
    }
    process.waitUntilExit(); drained.wait()
    if cancelledAt != nil || Task.isCancelled || FileManager.default.fileExists(atPath: cancel.path) {
        throw ffmpegError("Export cancelled")
    }
    let status = log.status(duration: duration)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
    // FFmpeg may exit successfully after refusing an existing output (-n).
    // Require an actual completed encode, not just a zero process exit status.
    guard process.terminationStatus == 0, status.2, bytes > 0 else {
        throw ffmpegError("FFmpeg HEVC encoding failed: " + log.status(duration: duration).1)
    }
}

private func ffmpegError(_ message: String) -> NSError {
    NSError(domain: "Saturn", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
