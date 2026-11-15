import Foundation
import AppKit
import CryptoKit
import ImageIO
import CoreMedia

/// Portable native cursor bitmap. Dimensions and hotspot are native screen
/// points, independent of bitmap resolution and the eventual export size.
struct CursorAsset: Codable {
    let png: Data
    let width: Double
    let height: Double
    let hotspotX: Double
    let hotspotY: Double

    var identifier: String {
        var data = png
        data.append(Data("\(width),\(height),\(hotspotX),\(hotspotY)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var cgImage: CGImage? {
        guard png.count <= 1_000_000,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 1024, h <= 1024 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    @MainActor static func system(_ cursor: NSCursor? = nil) -> CursorAsset? {
        let cursor = cursor ?? NSCursor.currentSystem ?? .arrow
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, image.size.height > 0, image.size.width <= 512, image.size.height <= 512,
              let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return CursorAsset(png: png, width: image.size.width, height: image.size.height,
                           hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y)
    }
}

struct CursorObservation {
    let hostUs: Int64
    let point: CGPoint
    let asset: CursorAsset?
    let leftClicks: UInt32
    let rightClicks: UInt32
    let leftClickAge: Double
    let rightClickAge: Double
    @MainActor static func current() -> CursorObservation? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        let left = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
        let right = CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown)
        let leftAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let rightAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown)
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        return CursorObservation(hostUs: CMTimeConvertScale(host, timescale: 1_000_000, method: .roundTowardZero).value,
                                 point: point, asset: CursorAsset.system(), leftClicks: left, rightClicks: right,
                                 leftClickAge: leftAge, rightClickAge: rightAge)
    }
}

let cursorMagnification = 2.0

/// Sprite geometry is relative to the real click hotspot, with Core Animation's
/// bottom-left coordinates. Scaling the image must never move the click point.
func cursorSpriteRect(asset: CursorAsset, pixelScaleX: Double, pixelScaleY: Double) -> CGRect {
    let sx = pixelScaleX * cursorMagnification
    let sy = pixelScaleY * cursorMagnification
    return CGRect(x: -asset.hotspotX * sx, y: -(asset.height - asset.hotspotY) * sy,
                  width: asset.width * sx, height: asset.height * sy)
}
