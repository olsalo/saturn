import Foundation
import AppKit
import ImageIO

@main struct ThumbnailResolutionTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(Array(data.prefix(2)) == [255, 216], "Thumbnail must be encoded as JPEG")
        if CommandLine.arguments.contains("--shrink") {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960] as CFDictionary)!
            let small = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
            try small.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            return
        }
        let bitmap = NSBitmapImageRep(data: data)!
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let jfif = properties[kCGImagePropertyJFIFDictionary] as! [CFString: Any]
        precondition(jfif[kCGImagePropertyJFIFIsProgressive] as? Bool == true, "Use progressive JPEG encoding")
        precondition(bitmap.pixelsWide == 1280 && bitmap.pixelsHigh == 800, "Match the poster’s 1280-pixel long-edge cap")
        print("Thumbnail passed: progressive JPEG, 1280×800, matching poster bounds.")
    }
}
