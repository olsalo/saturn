import Foundation
import AppKit

@main struct CursorAppearanceTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let arrow = CursorAsset.system(.arrow)!
        let text = CursorAsset.system(.iBeam)!
        let hand = CursorAsset.system(.pointingHand)!
        assert(arrow.identifier != text.identifier && text.identifier != hand.identifier)
        assert(arrow.cgImage != nil && text.cgImage != nil && hand.cgImage != nil)
        let rect = cursorSpriteRect(asset: arrow, pixelScaleX: 2, pixelScaleY: 2)
        assert(abs(rect.width - arrow.width * 4.0) < 0.001, "Retina cursor must be exactly 2 times native size")
        assert(abs(rect.minX + arrow.hotspotX * 4.0) < 0.001)
        assert(abs(rect.maxY - arrow.hotspotY * 4.0) < 0.001, "Image changes must keep the click hotspot fixed")
        let events: [[String: Any]] = [
            ["tUs":0,"x":20.0,"y":20.0,"visible":true,"cursorID":"arrow","cursorScaleX":2.0,"cursorScaleY":2.0],
            ["tUs":1_000_000,"x":20.0,"y":20.0,"visible":true,"cursorID":"text","cursorScaleX":2.0,"cursorScaleY":2.0],
            ["tUs":1_500_000,"x":20.0,"y":20.0,"visible":true,"cursorID":"hand","cursorScaleX":2.0,"cursorScaleY":2.0]
        ]
        let timeline = cursorTimeline(events, durationUs: 2_000_000)
        assert(timeline.first { $0.timeUs == 999_999 }?.cursorID == "arrow")
        assert(timeline.first { $0.timeUs == 1_000_000 }?.cursorID == "text")
        assert(timeline.last?.cursorID == "hand" && timeline.last?.pixelScaleX == 2)
        let restored = try JSONDecoder().decode([String: CursorAsset].self, from: JSONEncoder().encode(["arrow":arrow,"text":text,"hand":hand]))
        assert(restored["arrow"]?.identifier == arrow.identifier)
        if CommandLine.arguments.count > 1 {
            try JSONEncoder().encode(["arrow":arrow,"text":text,"hand":hand]).write(to: URL(fileURLWithPath:CommandLine.arguments[1]))
        }
        print("Native cursors passed: arrow/text/hand bitmaps, portable assets, 2x Retina size, fixed hotspots, and timestamped shape changes.")
    }
}
