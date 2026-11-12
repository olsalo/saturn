import Foundation

@main struct EncoderCancellationTests {
    static func main() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("saturn-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cancel = folder.appendingPathComponent("cancel")
        let encoder: ExportEncoder = .ffmpeg
        do {
            try await encodeVideo(input: URL(fileURLWithPath: CommandLine.arguments[1]),
                output: folder.appendingPathComponent("cancelled.mp4"), cancel: cancel, encoder: encoder) { _ in
                    // Callback occurs only after the encoder process was launched.
                    try? Data().write(to: cancel)
                }
            fatalError("A cancelled HEVC encode reported success")
        } catch {
            assert(error.localizedDescription == "Export cancelled", error.localizedDescription)
            print("\(encoder.rawValue) active cancellation passed: a launched encoder returns cancellation, never completion.")
        }
    }
}
