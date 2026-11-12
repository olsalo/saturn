import Foundation
import ImageIO

@main struct WebExportTests {
    static func frontLoadedCues(_ data: Data) -> Bool {
        func value(_ offset: inout Int, id: Bool) -> UInt64? {
            guard offset < data.count, data[offset] != 0 else { return nil }
            let length = data[offset].leadingZeroBitCount + 1
            guard length <= 8, offset + length <= data.count else { return nil }
            var result = UInt64(id ? data[offset] : data[offset] & (0xff >> length))
            for index in 1..<length { result = (result << 8) | UInt64(data[offset + index]) }
            offset += length
            return result
        }
        var offset = 0
        while offset < data.count {
            guard let id = value(&offset, id: true), let size = value(&offset, id: false) else { return false }
            if id == 0x18538067 { break } // Inspect the Segment's direct children.
            guard size <= UInt64(data.count - offset) else { return false }
            offset += Int(size)
        }
        while offset < data.count {
            guard let id = value(&offset, id: true), let size = value(&offset, id: false) else { return false }
            if id == 0x1C53BB6B { return true }
            if id == 0x1F43B675 { return false }
            guard size <= UInt64(data.count - offset) else { return false }
            offset += Int(size)
        }
        return false
    }
    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("website")
        let cancel = root.appendingPathComponent("cancel")
        try validateExportEncoder(.web)
        var progress = 0.0
        try await encodeWebsite(input: input, folder: folder, cancel: cancel, duration: 2) { event in
            let next = event["fraction"] as! Double
            precondition(next >= progress && next < 1, "Website progress moved backwards")
            progress = next
        }
        for (file, codec) in [("video-av1.webm", "av1"), ("video-vp9.webm", "vp9")] {
            let url = folder.appendingPathComponent(file)
            let data = try Data(contentsOf: url)
            let info = try probeFFmpeg(url)
            let streams = info["streams"] as! [[String: Any]]
            precondition(streams.contains { $0["codec_name"] as? String == codec })
            precondition(streams.contains { $0["codec_name"] as? String == "opus" })
            precondition(data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]), "WebM EBML header is missing")
            precondition(frontLoadedCues(data), "WebM seek metadata was not front-loaded")
        }
        let thumbnail = folder.appendingPathComponent("poster.jpg")
        guard let imageSource = CGImageSourceCreateWithURL(thumbnail as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            fatalError("Thumbnail is not a readable image")
        }
        precondition(max(image.width, image.height) <= 1280 && image.width > 0 && image.height > 0)
        let html = try String(contentsOf: folder.appendingPathComponent("embed.html"), encoding: .utf8)
        precondition(html.contains("poster=\"poster.jpg\""))
        precondition(html.contains("av01.0.") && html.contains("vp9") && html.contains("opus"))
        precondition(html.range(of: "video-av1.webm")!.lowerBound < html.range(of: "video-vp9.webm")!.lowerBound)
        do {
            try await encodeWebsite(input: input, folder: folder, cancel: cancel, duration: 2) { _ in }
            fatalError("Website export overwrote an existing folder")
        } catch {
            let retained = try String(contentsOf: folder.appendingPathComponent("embed.html"), encoding: .utf8)
            precondition(retained == html)
        }
        let cancelled = root.appendingPathComponent("cancelled")
        do {
            try await encodeWebsite(input: input, folder: cancelled, cancel: cancel, duration: 2) { event in
                if (event["fraction"] as? Double ?? 0) >= 0.75 { try? Data().write(to: cancel) }
            }
            fatalError("A cancelled website export reported success")
        } catch {
            precondition(error.localizedDescription == "Export cancelled", error.localizedDescription)
            precondition(!FileManager.default.fileExists(atPath: cancelled.path))
        }
        try FileManager.default.removeItem(at: cancel)
        print("Website export passed: AV1 primary, VP9 fallback, Opus audio, full decode, duration, codec declarations, streaming headers, monotonic progress, existing-folder protection and cancellation cleanup.")
    }
}
