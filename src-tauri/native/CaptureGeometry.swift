import Foundation
import CoreGraphics

/// Coordinate contract for a display stream cropped to a visible window area.
/// Quartz window/display rectangles use global points with a top-left origin.
struct CaptureArea: Equatable {
    let sourceRect: CGRect
    let globalFrame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    static func display(_ display: CGRect, scale: CGFloat) throws -> CaptureArea {
        guard display.width > 0, display.height > 0, scale.isFinite, scale > 0 else {
            throw NSError(domain: "Saturn", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected screen is unavailable."])
        }
        let width = Int(floor(display.width * scale)) / 2 * 2
        let height = Int(floor(display.height * scale)) / 2 * 2
        guard width >= 2, height >= 2 else {
            throw NSError(domain: "Saturn", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected screen is too small to record."])
        }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return CaptureArea(sourceRect: rect, globalFrame: rect.offsetBy(dx: display.minX, dy: display.minY), pixelWidth: width, pixelHeight: height)
    }

    static func window(_ window: CGRect, on display: CGRect, scale: CGFloat) throws -> CaptureArea {
        guard [window.minX, window.minY, window.width, window.height,
               display.minX, display.minY, display.width, display.height, scale].allSatisfy({ $0.isFinite }),
              window.width >= 2, window.height >= 2, display.width > 0, display.height > 0, scale > 0,
              display.insetBy(dx: -0.5, dy: -0.5).contains(window) else {
            throw NSError(domain: "Saturn", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Keep the whole selected window on one display. Recording stops if it leaves that display."])
        }
        // Crop inward to physical pixels, removing the outer one-pixel native
        // border/shadow fringe. Source and encoded dimensions then agree exactly;
        // do not stretch a fractional-point rectangle into floored even pixels.
        let local = window.intersection(display).offsetBy(dx: -display.minX, dy: -display.minY)
        let x = ceil(local.minX * scale) + 1
        let y = ceil(local.minY * scale) + 1
        let width = Int(floor(local.maxX * scale) - 1 - x) / 2 * 2
        let height = Int(floor(local.maxY * scale) - 1 - y) / 2 * 2
        guard width >= 2, height >= 2 else {
            throw NSError(domain: "Saturn", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected window is too small to record."])
        }
        let rect = CGRect(x: x / scale, y: y / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return CaptureArea(sourceRect: rect, globalFrame: rect.offsetBy(dx: display.minX, dy: display.minY),
                           pixelWidth: width, pixelHeight: height)
    }
}

/// Recordly linked padding maps 0–100 to 0–20% of each canvas dimension.
func exportVideoRect(source: CGSize, canvas: CGSize, paddingPercent: Double?, paddingPixels: Double, none: Bool) -> CGRect {
    let fraction = none ? 0 : (paddingPercent.map { min(100, max(0, $0)) / 100 * 0.2 } ?? 0)
    let px = none ? 0 : (paddingPercent == nil ? paddingPixels : canvas.width * fraction)
    let py = none ? 0 : (paddingPercent == nil ? paddingPixels : canvas.height * fraction)
    let scale = min((canvas.width - 2 * px) / source.width, (canvas.height - 2 * py) / source.height)
    let size = CGSize(width: source.width * scale, height: source.height * scale)
    return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
}

/// The video compositor and Core Animation rasterize fractional edges
/// differently. Mask only fully covered destination pixels, with a half-pixel
/// resampling guard, so the compositor's black canvas cannot leak into the rim.
/// Source crop and the aspect-preserving video transform remain unchanged.
func exportVideoMaskRect(_ rect: CGRect) -> CGRect {
    let left = ceil(rect.minX + 0.5), right = floor(rect.maxX - 0.5)
    let bottom = ceil(rect.minY + 0.5), top = floor(rect.maxY - 0.5)
    guard right > left, top > bottom else { return rect }
    return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
}

/// Corner radius is authored for a 2560-pixel canvas; keep its visual size
/// consistent as dynamic export dimensions change.
func exportCornerRadius(_ radius: CGFloat, canvasWidth: CGFloat) -> CGFloat {
    return radius * canvasWidth / 2560
}
