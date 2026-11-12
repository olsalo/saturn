import Foundation

enum ExportEncoder: String {
    case ffmpeg, av1, vp9, h264, web
    static let defaultEncoder: ExportEncoder = .ffmpeg
}

func validateExportEncoder(_ encoder: ExportEncoder) throws {
    if encoder == .web {
        _ = try ffmpegTool("ffprobe")
        try validateFFmpegEncoder(.av1)
        try validateFFmpegEncoder(.vp9)
    } else {
        try validateFFmpegEncoder(encoder)
    }
}
