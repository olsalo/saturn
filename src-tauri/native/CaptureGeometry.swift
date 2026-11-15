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

/// Linked padding maps 0–100 to 0–20% of each canvas dimension.
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

/// Recover the minimum circular mask that covers a recorded black corner matte.
/// Measure in source pixels: a small window's native corners grow along with
/// the footage, independently of the canvas-relative appearance radius.
func recordedCornerRadius(_ image: CGImage) -> CGFloat {
    let width = image.width, height = image.height
    let reach = min(128, min(width, height) / 3)
    guard reach >= 8 else { return 0 }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { storage in
        guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = storage.bindMemory(to: UInt8.self)
        var radius: CGFloat = 0
        for (right, bottom) in [(false, false), (true, false), (false, true), (true, true)] {
            func index(_ x: Int, _ y: Int) -> Int {
                ((bottom ? height - 1 - y : y) * width + (right ? width - 1 - x : x)) * 4
            }
            let seed = index(0, 0)
            guard bytes[seed + 3] >= 250, (0..<3).allSatisfy({ bytes[seed + $0] <= 40 }) else { continue }
            let samples = (reach * 3 / 4..<reach).map { index($0, 0) }
            let reference = (0..<3).map { channel -> Double in
                let values = samples.map { Double(bytes[$0 + channel]) }.sorted()
                return values[values.count / 2]
            }
            guard reference.max()! >= 32,
                  samples.allSatisfy({ i in (0..<3).allSatisfy { abs(Double(bytes[i + $0]) - reference[$0]) <= 20 } }) else { continue }
            let norm = reference.reduce(0) { $0 + $1 * $1 }
            func alpha(_ i: Int) -> Double {
                (0..<3).reduce(0) { $0 + Double(bytes[i + $1]) * reference[$1] } / norm
            }
            guard alpha(seed) < 0.5 else { continue }
            guard alpha(index(reach - 1, 0)) >= 0.94, alpha(index(0, reach - 1)) >= 0.94 else { continue }
            var pending = [(0, 0)]
            var visited = Set<Int>()
            var candidate: CGFloat = 0
            var bounded = true
            while let (x, y) = pending.popLast() {
                guard x >= 0, y >= 0, x < reach, y < reach,
                      visited.insert(y * reach + x).inserted else { continue }
                let i = index(x, y), a = alpha(i)
                guard a < 0.94, bytes[i + 3] >= 250,
                      (0..<3).allSatisfy({ abs(Double(bytes[i + $0]) - reference[$0] * a) <= 16 }) else { continue }
                if x == reach - 1 || y == reach - 1 { bounded = false; break }
                // For a pixel's inner corner, solve (r-x)^2+(r-y)^2=r^2.
                // One source pixel also covers compression and resampling fringe.
                let px = CGFloat(x + 1), py = CGFloat(y + 1)
                candidate = max(candidate, px + py + sqrt(2 * px * py) + 1)
                pending += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            }
            if bounded && candidate <= CGFloat(reach) { radius = max(radius, candidate) }
        }
        return radius
    }
}
