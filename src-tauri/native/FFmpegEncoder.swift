import Foundation
import Darwin
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

func ffmpegExecutable() throws -> URL { try ffmpegTool("ffmpeg") }

func ffmpegTool(_ name: String) throws -> URL {
    let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
#if arch(arm64)
    let target = "aarch64-apple-darwin"
#else
    let target = "x86_64-apple-darwin"
#endif
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src-tauri/binaries/" + name + "-" + target)
    guard let url = [sibling, development].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw ffmpegError("The bundled \(name) tool is missing. Run npm run setup:encoder, then rebuild Saturn.")
    }
    return url
}

private let ffmpegVideoOptions = [
    "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le",
    "-q:v", "57", "-allow_sw", "0", "-realtime", "0", "-prio_speed", "0",
    // Use a ~10-second GOP at the 30fps export ceiling and allow
    // frame reordering. FFmpeg's 12-frame default inflates static UI recordings.
    "-g", "301", "-bf", "2",
]

private func ffmpegVideoOptions(for encoder: ExportEncoder) -> [String] {
    switch encoder {
    case .av1:
        return ["-c:v", "libaom-av1", "-pix_fmt", "yuv420p", "-crf", "32", "-b:v", "0",
                "-usage", "good", "-cpu-used", "6", "-row-mt", "1", "-threads", "4",
                "-g", "301", "-aom-params", "tune-content=screen"]
    case .vp9:
        return ["-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-crf", "32", "-b:v", "0",
                "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-threads", "4",
                "-g", "301", "-tune-content", "screen"]
    case .h264:
        let options = ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p",
                "-allow_sw", "0", "-realtime", "0", "-prio_speed", "0",
                "-g", "301", "-bf", "2"]
#if arch(arm64)
        return options + ["-q:v", "65"]
#else
        // FFmpeg's VideoToolbox constant-quality mode requires Apple Silicon.
        return options + ["-b:v", "8M"]
#endif
    default:
        return ffmpegVideoOptions
    }
}

func ffmpegArguments(input: URL, output: URL, duration: Double?, encoder: ExportEncoder = .ffmpeg) -> [String] {
    let web = encoder == .av1 || encoder == .vp9
    var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-n",
                "-progress", "pipe:1", "-i", input.path,
                "-map", "0:v:0", "-map", "0:a?",
                "-vf", "fps=fps='min(source_fps,30)'"] + ffmpegVideoOptions(for: encoder)
    if web {
        args += ["-c:a", "libopus", "-vbr", "on", "-b:a", "128k", "-ac", "2",
                 "-f", "webm", "-cues_to_front", "1"]
    } else {
        // Constrained VBR retains the 128k target without padding silence.
        args += ["-tag:v", encoder == .h264 ? "avc1" : "hvc1", "-c:a", "aac_at",
                 "-aac_at_mode", "cvbr", "-b:a", "128k", "-ac", "2", "-movflags", "+faststart"]
    }
    if let duration {
        args += ["-t", String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), duration)]
    }
    return args + [output.path]
}

func validateFFmpegEncoder(_ encoder: ExportEncoder = .ffmpeg) throws {
    // Exercise the actual hardware, not just the list of compiled-in encoders.
    // Fail before the expensive ProRes compositor pass on unsupported machines.
    let process = Process()
    process.executableURL = try ffmpegExecutable()
    process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error",
                         "-f", "lavfi", "-i", "color=size=64x64:rate=30",
                         "-frames:v", "1", "-an"] + ffmpegVideoOptions(for: encoder) + ["-f", "null", "-"]
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit(); pipe.fileHandleForReading.closeFile()
    guard process.terminationStatus == 0 else {
        throw ffmpegError("FFmpeg \(encoder.rawValue) encoding is unavailable on this Mac. " + String(message.suffix(3000)))
    }
}

private final class FFmpegLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var seconds = 0.0
    private var completed = false
    private var frames = 0
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text += String(decoding: data, as: UTF8.self)
        if text.count > 32768 { text = String(text.suffix(32768)) }
        // Only parse complete lines: a progress update may span pipe reads.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if line == "progress=end" { completed = true }
            if line.hasPrefix("frame="), let value = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) { frames = max(frames, value) }
            if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)) {
                seconds = max(seconds, value / 1_000_000)
            }
        }
    }
    func status(duration: Double?) -> (Double, String, Bool, Double, Int) {
        lock.lock(); defer { lock.unlock() }
        let fraction = duration.map { $0 > 0 ? min(1, seconds / $0) : 0 } ?? 0
        return (fraction, String(text.suffix(3000)), completed, seconds, frames)
    }
}

func encodeVideo(input: URL, output: URL, cancel: URL, duration: Double? = nil,
                 encoder: ExportEncoder = .defaultEncoder, report: @escaping ([String: Any]) -> Void) async throws {
    let label = encoder == .av1 ? "AV1" : encoder == .vp9 ? "VP9" : encoder == .h264 ? "H.264" : "HEVC"
    guard encoder != .web else { throw ffmpegError("Website export requires a destination folder") }
    if FileManager.default.fileExists(atPath: cancel.path) { throw ffmpegError("Export cancelled") }
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw ffmpegError("FFmpeg \(label) encoding failed: the output file already exists.")
    }
    let status = try await runFFmpeg(arguments: ffmpegArguments(input: input, output: output, duration: duration, encoder: encoder),
                                     cancel: cancel, duration: duration, label: "\(label) encoding", report: report)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
    guard status.4 > 0, bytes > 0 else { throw ffmpegError("FFmpeg \(label) encoding failed: no video was produced") }
}

private func runFFmpeg(arguments: [String], cancel: URL, duration: Double?, label: String,
                       report: @escaping ([String: Any]) -> Void) async throws -> (Double, String, Bool, Double, Int) {
    if FileManager.default.fileExists(atPath: cancel.path) { throw ffmpegError("Export cancelled") }
    let process = Process()
    process.executableURL = try ffmpegExecutable()
    process.arguments = arguments
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
    var cancelledAt: Date?
    while process.isRunning {
        if Task.isCancelled || FileManager.default.fileExists(atPath: cancel.path) {
            if cancelledAt == nil { cancelledAt = Date(); process.terminate() }
            else if Date().timeIntervalSince(cancelledAt!) > 3 { kill(process.processIdentifier, SIGKILL) }
        }
        report(["type": "progress", "fraction": 0.4 + log.status(duration: duration).0 * 0.59])
        // Keep the polling delay even after Swift task cancellation. The child
        // gets SIGTERM, then SIGKILL after the grace period, and is always drained.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { continuation.resume() }
        }
    }
    // Foundation's waitUntilExit uses a thread run loop. After an async
    // suspension this may be a different thread from run(), which can hang.
    // isRunning is already false; await pipe EOF without blocking a Swift worker.
    await withCheckedContinuation { continuation in
        drained.notify(queue: .global()) { continuation.resume() }
    }
    pipe.fileHandleForReading.closeFile()
    if cancelledAt != nil || Task.isCancelled || FileManager.default.fileExists(atPath: cancel.path) {
        throw ffmpegError("Export cancelled")
    }
    let status = log.status(duration: duration)
    guard process.terminationStatus == 0, status.2 else {
        throw ffmpegError("FFmpeg \(label) failed: " + status.1)
    }
    return status
}

private func ffmpegError(_ message: String) -> NSError {
    NSError(domain: "Saturn", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func probeFFmpeg(_ url: URL) throws -> [String: Any] {
    let process = Process()
    process.executableURL = try ffmpegTool("ffprobe")
    process.arguments = ["-v", "error", "-show_streams", "-show_format", "-show_data", "-of", "json", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit(); pipe.fileHandleForReading.closeFile()
    guard process.terminationStatus == 0,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ffmpegError("Could not inspect the exported video")
    }
    return object
}

private func webCodec(_ stream: [String: Any]) throws -> String {
    // Read the codec configuration bytes supplied by ffprobe, so the embed
    // advertises the actual profile/level rather than a hardcoded resolution.
    if stream["codec_name"] as? String == "vp9" { return "vp9" }
    let dump = stream["extradata"] as? String ?? ""
    var bytes: [UInt8] = []
    for line in dump.split(separator: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let hex = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "  ")[0].replacingOccurrences(of: " ", with: "")
        for offset in stride(from: 0, to: hex.count - 1, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: offset)
            if let byte = UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) { bytes.append(byte) }
        }
    }
    guard bytes.count >= 4 else { throw ffmpegError("Missing web codec configuration") }
    if stream["codec_name"] as? String == "av1" {
        let profile = bytes[1] >> 5, level = bytes[1] & 31
        let tier = bytes[2] & 128 == 0 ? "M" : "H"
        let depth = bytes[2] & 64 == 0 ? 8 : bytes[2] & 32 == 0 ? 10 : 12
        return String(format: "av01.%d.%02d%@.%02d", profile, level, tier, depth)
    }
    return String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
}

func encodeWebsite(input: URL, folder: URL, cancel: URL, duration: Double,
                   report: @escaping ([String: Any]) -> Void) async throws {
    guard !FileManager.default.fileExists(atPath: folder.path) else {
        throw ffmpegError("Website export destination already exists")
    }
    _ = try ffmpegTool("ffprobe")
    let source = try probeFFmpeg(input)
    let sourceStreams = source["streams"] as? [[String: Any]] ?? []
    let sourceAudioCount = sourceStreams.filter { $0["codec_type"] as? String == "audio" }.count
    guard let sourceVideo = sourceStreams.first(where: { $0["codec_type"] as? String == "video" }) else {
        throw ffmpegError("Website export source has no video")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    var finished = false
    defer { if !finished { try? FileManager.default.removeItem(at: folder) } }
    let formats: [(ExportEncoder, String, Double, Double)] = [(.av1, "video-av1.webm", 0.4, 0.35), (.vp9, "video-vp9.webm", 0.75, 0.18)]
    for (encoder, filename, start, span) in formats {
        try await encodeVideo(input: input, output: folder.appendingPathComponent(filename), cancel: cancel,
                              duration: duration, encoder: encoder) { value in
            let fraction = min(1, max(0, ((value["fraction"] as? Double ?? 0.4) - 0.4) / 0.59))
            report(["type": "progress", "fraction": start + span * fraction])
        }
    }
    var codecs: [String] = []
    for (index, format) in formats.enumerated() {
        let url = folder.appendingPathComponent(format.1)
        let info = try probeFFmpeg(url)
        let streams = info["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              video["codec_name"] as? String == (format.0 == .av1 ? "av1" : "vp9"),
              video["width"] as? Int == sourceVideo["width"] as? Int,
              video["height"] as? Int == sourceVideo["height"] as? Int,
              streams.filter({ $0["codec_type"] as? String == "audio" }).count == sourceAudioCount else {
            throw ffmpegError("Website export codec, dimensions or audio validation failed")
        }
        let stats = try await runFFmpeg(arguments: ["-hide_banner", "-nostdin", "-loglevel", "error", "-xerror",
                                                   "-progress", "pipe:1", "-i", url.path,
                                                   "-map", "0:v:0", "-an", "-f", "null", "-"],
                                        cancel: cancel, duration: duration, label: "web video validation") { value in
            let fraction = min(1, max(0, ((value["fraction"] as? Double ?? 0.4) - 0.4) / 0.59))
            report(["type": "progress", "fraction": 0.93 + Double(index) * 0.03 + fraction * 0.03])
        }
        guard stats.4 > 0, abs(stats.3 - duration) <= 1.0 / 30 + 0.001 else {
            throw ffmpegError("Website export has incomplete video frames")
        }
        let container = info["format"] as? [String: Any] ?? [:]
        guard let length = Double(container["duration"] as? String ?? ""), abs(length - duration) <= 1.0 / 30 + 0.001 else {
            throw ffmpegError("Website export duration changed")
        }
        codecs.append(try webCodec(video) + (sourceAudioCount > 0 ? ",opus" : ""))
    }
    if FileManager.default.fileExists(atPath: cancel.path) || Task.isCancelled { throw ffmpegError("Export cancelled") }
    // Use the compositor's first frame, avoiding a dependency on macOS AV1 decoding.
    // Cap the long edge for a small, broadly supported loading image.
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 1280)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: .zero).image
    let thumbnail = folder.appendingPathComponent("poster.jpg")
    guard let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ffmpegError("Could not create website thumbnail")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ffmpegError("Could not save website thumbnail") }
    if FileManager.default.fileExists(atPath: cancel.path) || Task.isCancelled { throw ffmpegError("Export cancelled") }
    let width = sourceVideo["width"] as? Int ?? 2560, height = sourceVideo["height"] as? Int ?? 1600
    let html = """
    <!doctype html>
    <html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Recording</title>
    <video controls playsinline preload="metadata" poster="poster.jpg" width="\(width)" height="\(height)" style="display:block;max-width:100%;height:auto">
      <source src="video-av1.webm" type='video/webm; codecs="\(codecs[0])"'>
      <source src="video-vp9.webm" type='video/webm; codecs="\(codecs[1])"'>
      <a href="video-vp9.webm">Download the video</a>
    </video></html>
    """
    try html.write(to: folder.appendingPathComponent("embed.html"), atomically: true, encoding: .utf8)
    try "Upload video-av1.webm, video-vp9.webm, poster.jpg and embed.html together to your website. Copy the <video> element from embed.html into your page. The browser selects AV1 when supported, otherwise VP9. The thumbnail is the first frame, optimized for use as a poster. Both videos contain the selected audio as Opus and streamable WebM headers and front-loaded seek metadata. AV1 encoding uses software; VP9 also uses software.\n".write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    finished = true
}
