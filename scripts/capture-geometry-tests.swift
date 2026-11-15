import Foundation
import CoreGraphics
@main struct GeometryTests {
    static func main() throws {
        let screen = try CaptureArea.display(CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 2)
        assert(screen.sourceRect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        assert(screen.globalFrame == CGRect(x: -1920, y: -200, width: 1920, height: 1080))
        assert(screen.pixelWidth == 3840 && screen.pixelHeight == 2160)
        // Retina main display: point offsets remain points; output dimensions are pixels.
        let main = try CaptureArea.window(CGRect(x: 100, y: 80, width: 801, height: 501), on: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
        assert(main.sourceRect == CGRect(x: 100.5, y: 80.5, width: 800, height: 500))
        assert(main.pixelWidth == 1600 && main.pixelHeight == 1000)
        // A monitor to the left/above the main monitor must not crop the wrong area.
        let left = try CaptureArea.window(CGRect(x: -1800, y: -100, width: 700, height: 500), on: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)
        assert(left.sourceRect == CGRect(x: 121, y: 101, width: 698, height: 498))
        assert(left.pixelWidth == 698 && left.pixelHeight == 498)
        let fractional = try CaptureArea.window(CGRect(x: 10.5, y: 20.5, width: 800.5, height: 499.5), on: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        assert(fractional.pixelWidth == 798 && fractional.pixelHeight == 496)
        for area in [main, left, fractional] {
            let scale: CGFloat = area == main ? 2 : 1
            assert(area.sourceRect.width * scale == CGFloat(area.pixelWidth))
            assert(area.sourceRect.height * scale == CGFloat(area.pixelHeight))
            assert(area.sourceRect.minX * scale == floor(area.sourceRect.minX * scale))
        }
        for invalid in [CGRect(x: -10, y: 20, width: 800, height: 500), CGRect(x: 1800, y: 20, width: 800, height: 500), .zero] {
            do { _ = try CaptureArea.window(invalid, on: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2); fatalError("Accepted an unsafe/out-of-display crop") }
            catch { }
        }
        assert(abs(exportCornerRadius(21, canvasWidth: 3584) - 29.4) < 0.0001)
        assert(exportCornerRadius(21, canvasWidth: 2560) == 21)
        // Native window corners retain their source-pixel size as the window
        // shrinks. The mask must grow with upscaled footage, not just the canvas.
        for width in [160, 320, 640, 1600] {
            let height = width * 5 / 8
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 24, cornerHeight: 24, transform: nil))
            context.fillPath()
            let measured = recordedCornerRadius(context.makeImage()!)
            assert(measured >= 24 && measured < 34, "Recover the native radius including its antialiased fringe at every window size: \(measured)")
            let destination = exportVideoRect(source: CGSize(width: width, height: height), canvas: CGSize(width: 1280, height: 800), paddingPercent: 38, paddingPixels: 64, none: false)
            let radius = max(exportCornerRadius(21, canvasWidth: 1280), measured * destination.width / CGFloat(width))
            assert(radius >= 24 * destination.width / CGFloat(width))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 24, cornerHeight: 24, transform: nil))
            context.fillPath()
            let darkRadius = recordedCornerRadius(context.makeImage()!)
            assert(darkRadius >= 24 && darkRadius < 34, "Dark window chrome must also hide its corner matte")
            // Square bright windows and solid black content need no inferred mask.
            for gray: CGFloat in [0, 0.2, 0.95] {
                context.setFillColor(CGColor(gray: gray, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                assert(recordedCornerRadius(context.makeImage()!) == 0)
            }
        }
        let layout = exportVideoRect(source: CGSize(width: 640, height: 400), canvas: CGSize(width: 1920, height: 1200), paddingPercent: 38, paddingPixels: 64, none: false)
        assert(abs(layout.minX - 145.92) < 0.0001 && abs(layout.minY - 91.2) < 0.0001, "Match 38% padding: 7.6% of each canvas dimension per edge")
        assert(abs(layout.width - 1628.16) < 0.0001 && abs(layout.height - 1017.6) < 0.0001)
        let noBackground = exportVideoRect(source: CGSize(width: 640, height: 400), canvas: CGSize(width: 1920, height: 1200), paddingPercent: 38, paddingPixels: 64, none: true)
        assert(noBackground == CGRect(x:0,y:0,width:1920,height:1200))
        let fractionalEdge = exportVideoRect(source: CGSize(width:3022,height:1896), canvas:CGSize(width:3456,height:2160), paddingPercent:38,paddingPixels:64,none:false)
        let safeMask = exportVideoMaskRect(fractionalEdge)
        assert(safeMask.minX.rounded() == safeMask.minX && safeMask.maxX.rounded() == safeMask.maxX)
        assert(safeMask.minY.rounded() == safeMask.minY && safeMask.maxY.rounded() == safeMask.maxY)
        assert(fractionalEdge.contains(safeMask) && safeMask.maxX <= fractionalEdge.maxX - 0.5)
        assert(fractionalEdge.width - safeMask.width < 3 && fractionalEdge.height - safeMask.height < 3, "Mask guard must not change the window crop or scale")
        print("Capture geometry passed: Retina, negative display origins, even encoder dimensions, and rejection of off-display/empty areas.")
    }
}
