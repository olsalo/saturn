import Foundation
import CoreGraphics

@main struct CursorStartupTests {
    static func main() throws {
        guard #available(macOS 15.0, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let capture = Capture(cursor: handle)
        capture.frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        capture.dimensions = CGSize(width: 800, height: 600)
        func observation(_ time: Int64, _ x: Double, clicks: UInt32 = 5) -> CursorObservation {
            CursorObservation(hostUs: time, point: CGPoint(x: x, y: 120), asset: nil,
                              leftClicks: clicks, rightClicks: 0, leftClickAge: 0.01, rightClickAge: 10)
        }
        capture.sampleCursor(observation(950_000, 110))
        capture.sampleCursor(observation(990_000, 120))
        capture.anchorCursor(videoPTSUs: 1_000_000)
        capture.sampleCursor(observation(1_050_000, 150, clicks: 6))
        capture.anchorCursor(videoPTSUs: 1_100_000)
        capture.sampleCursor(observation(1_120_000, 160, clicks: 6))
        try handle.synchronize()
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        assert(events.count == 3, "Only one startup event, with no pre-video samples")
        assert((events[0]["tUs"] as? Int) == 0 && (events[0]["x"] as? Double) == 40,
               "Use the latest startup observation on the very first video frame")
        assert(events[0]["click"] == nil, "Startup must establish a click baseline")
        assert((events[1]["tUs"] as? Int) == 50_000 && (events[2]["tUs"] as? Int) == 120_000,
               "Preserve real observation times and the original video origin")
        assert(events[1]["click"] as? Bool == true && (events[1]["clickUs"] as? Int) == 40_000)
        let timeline = cursorTimeline(events, durationUs: 200_000)
        assert(timeline.first?.timeUs == 0 && timeline.first?.visible == true,
               "The rendered cursor must be visible from frame zero")
        print("Cursor startup passed: first-frame visibility, latest startup position, unchanged movement timestamps and click timing.")
    }
}
