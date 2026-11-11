import Foundation
import AVFoundation
import AppKit

/// Check the actual encoded compositor output, not just the animation builder.
@main struct VerifyCursorRender {
    static func main() async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let assets = try JSONDecoder().decode([String: CursorAsset].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let backgroundURL = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/background.jpg")
        let background = NSBitmapImageRep(data: try Data(contentsOf: backgroundURL))!
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let width = Double(size.width), height = Double(size.height)
        let top = height * 0.076
        let scale = (height - 2 * top) / 400
        let left = (width - 640 * scale) / 2
        // Fixture pointer holds x=80 until 1s, then arrives at x=500 at 1s.
        // y=40 keeps it away from the synthetic video rectangle and toolbar.
        var arrowAreas: [Int] = []
        let bounce = cursorBounceTimeline([["tUs":500_000,"click":true,"visible":true]], durationUs:2_000_000)
        for (seconds, sourceX, sourceY) in [(14.0/30, 80.0, 60.0), (0.5, 80.0, 60.0), (16.0/30, 80.0, 60.0), (19.0/30, 80.0, 60.0), (0.8, 80.0, 60.0), (1.0, 500.0, 60.0), (1.5, 500.0, 60.0), (1.8, 638.0, 200.0), (1.9, 650.0, 200.0), (59.0/30, 650.0, 200.0)] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 30)).image
            let bitmap = NSBitmapImageRep(cgImage: image)
            let bgScale = max(width / Double(background.pixelsWide), height / Double(background.pixelsHigh))
            let bx = Int((10 + (Double(background.pixelsWide) * bgScale - width) / 2) / bgScale)
            let by = Int((height / 2 + (Double(background.pixelsHigh) * bgScale - height) / 2) / bgScale)
            let expectedBG = background.colorAt(x: bx, y: by)!.usingColorSpace(.deviceRGB)!
            let actualBG = bitmap.colorAt(x: 10, y: Int(height / 2))!.usingColorSpace(.deviceRGB)!
            assert(abs(expectedBG.redComponent - actualBG.redComponent) < 0.12 && abs(expectedBG.greenComponent - actualBG.greenComponent) < 0.12 && abs(expectedBG.blueComponent - actualBG.blueComponent) < 0.12, "Embedded wallpaper must fill the exported canvas using centered aspect fill")
            let x = Int((left + sourceX * scale).rounded())
            let y = Int((top + sourceY * scale).rounded())
            // Native arrow starts at its hotspot and extends downwards. Detect
            // its dark border, allowing a few pixels for H.264 and rasterization.
            let shape = seconds < 1 ? "arrow" : seconds < 1.5 ? "text" : "hand"
            let us = Int64(seconds * 1_000_000)
            var clickScale = 1.0
            for (a,b) in zip(bounce, bounce.dropFirst()) where a.timeUs <= us && us <= b.timeUs {
                clickScale = a.scale + (b.scale - a.scale) * Double(us - a.timeUs) / Double(b.timeUs - a.timeUs)
            }
            let asset = assets[shape]!
            let template = NSBitmapImageRep(cgImage: asset.cgImage!)
            var total = 0; var matched = 0
            for py in 0..<template.pixelsHigh {
                for px in 0..<template.pixelsWide {
                    guard let c = template.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                          c.alphaComponent > 0.95, max(c.redComponent, c.greenComponent, c.blueComponent) < 0.2 else { continue }
                    let dx = (Double(px) + 0.5) * asset.width / Double(template.pixelsWide) - asset.hotspotX
                    let dy = (Double(py) + 0.5) * asset.height / Double(template.pixelsHigh) - asset.hotspotY
                    let outputX = Int((left + (sourceX + dx * cursorMagnification * clickScale) * scale).rounded())
                    let outputY = Int((top + (sourceY + dy * cursorMagnification * clickScale) * scale).rounded())
                    total += 1
                    if let actual = bitmap.colorAt(x: outputX, y: outputY)?.usingColorSpace(.deviceRGB),
                       max(actual.redComponent, actual.greenComponent, actual.blueComponent) < 0.45 { matched += 1 }
                }
            }
            guard total > 0, Double(matched) / Double(total) > 0.70 else {
                throw NSError(domain: "CursorRenderTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wrong native cursor bitmap/scale/hotspot at \(seconds)s: \(shape), matched=\(matched)/\(total), hotspot=\(x),\(y)"])
            }
            if shape == "arrow" {
                var darkPixels = 0
                // The pointer is over a plain light area of the fixture.
                for px in (x-Int(45 * width / 3456))...(x+Int(290 * width / 3456)) { for py in (y-Int(45 * width / 3456))...(y+Int(290 * width / 3456)) {
                    if let c = bitmap.colorAt(x:px,y:py)?.usingColorSpace(.deviceRGB), max(c.redComponent,c.greenComponent,c.blueComponent) < 0.25 { darkPixels += 1 }
                } }
                arrowAreas.append(darkPixels)
            }
            let markerX = Int(left + 580 * scale)
            let markerY = Int(top + 100 * scale)
            guard let marker = bitmap.colorAt(x: markerX, y: markerY)?.usingColorSpace(.deviceRGB) else { fatalError("Missing marker pixel") }
            let tooltipVisible = marker.redComponent > 0.8 && marker.greenComponent < 0.5 && marker.blueComponent < 0.2
            assert(tooltipVisible == (seconds >= 1), "Tooltip marker appeared at the wrong video time")
            let tileX = Int(left + (30 + seconds * 30 * 4 + 60) * scale)
            let tileY = Int(top + 240 * scale)
            guard let tile = bitmap.colorAt(x: tileX, y: tileY)?.usingColorSpace(.deviceRGB) else { fatalError("Missing video pixel") }
            assert(tile.greenComponent > tile.redComponent && tile.greenComponent < 0.5, "Source animation frame was shifted in export at \(seconds)s: r=\(tile.redComponent) g=\(tile.greenComponent) b=\(tile.blueComponent) point=\(tileX),\(tileY)")

        }
        let normal = Double(arrowAreas[1])
        assert(abs(Double(arrowAreas[0]) / normal - 1) < 0.05, "No bounce before the recorded click")
        assert(Double(arrowAreas[2]) / normal < 0.96 && Double(arrowAreas[2]) / normal > 0.70, "Encoded cursor must compress on click: \(arrowAreas)")
        assert(Double(arrowAreas[3]) / normal > 1.01 && Double(arrowAreas[3]) / normal < 1.15, "Encoded cursor must rebound subtly: \(arrowAreas)")
        assert(abs(Double(arrowAreas[4]) / normal - 1) < 0.05, "Encoded cursor must settle to native 1.75x size")
        print("Encoded cursor render passed: no movement during a missing-data gap, exact arrival at the recorded timestamp, 1.75x native arrow/text/hand shapes at their exact hotspots, click compression/rebound/settling, unclipped sprites crossing the window edge and legacy movement outside it, source animation/tooltip frames remain on time, and the actual last encoded frame retains the final video content.")
    }
}
