import Foundation

// Shared bounds and quality for the saved preview and website poster.
let posterThumbnailMaxDimension = 1280.0
let posterThumbnailJPEGQuality = 0.8

enum ExportEncoder: String {
    case av1, vp9, h264, web
    static let defaultEncoder: ExportEncoder = .h264
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
