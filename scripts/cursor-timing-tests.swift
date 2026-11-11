import Foundation
import CoreGraphics

@main struct CursorTimingTests {
    static func event(_ us: Int64, _ x: Double, _ visible: Bool = true) -> [String: Any] {
        ["tUs": us, "x": x, "y": 100.0, "visible": visible]
    }
    static func main() {
        var clock = CursorClock()
        assert(clock.timestamp(hostUs: 999_000) == nil, "No cursor samples before the first video frame")
        clock.anchor(videoPTSUs: 1_000_000)
        assert(clock.timestamp(hostUs: 1_050_000) == 50_000, "Use observation time, including frame callback delay")
        clock.anchor(videoPTSUs: 1_100_000)
        assert(clock.timestamp(hostUs: 1_150_000) == 150_000, "Later frames must not reset the cursor origin")
        // No new video frames arrive during this static-screen interval.
        for us in stride(from: Int64(1_200_000), through: 3_000_000, by: 33_333) {
            assert(clock.timestamp(hostUs: us) == us - 1_000_000, "Cursor clock must advance while screen output is idle")
        }
        assert(clock.timestamp(hostUs: 1_500_000) == nil, "Never write duplicate or backwards timestamps")
        assert(clock.timestamp(hostUs: 999_999) == nil)

        let dense = cursorTimeline([event(0, 0), event(33_333, 50), event(66_666, 100)], durationUs: 100_000)
        assert(dense[1].point.x == 50 && dense[2].point.x == 100, "Smoothing must reach recorded positions at recorded times, with no low-pass lag")
        assert(dense.last?.point.x == 100 && dense.last?.timeUs == 100_000)

        let sparse = cursorTimeline([event(0, 10), event(2_000_000, 300)], durationUs: 3_000_000)
        assert(sparse[1] == CursorKeyframe(timeUs: 1_999_999, point: CGPoint(x: 10, y: 100), visible: true), "Do not invent a two-second traversal across missing cursor data")
        assert(sparse[2].point.x == 300 && sparse[2].timeUs == 2_000_000)
        let visibility = cursorTimeline([event(0, 10), event(33_333, 4000, false)], durationUs: 100_000)
        assert(visibility[1].point.x == 10 && visibility[1].timeUs == 33_332, "Do not interpolate a visible pointer toward an offscreen point")
        assert(!visibility[2].visible)

        let canvasEvents = cursorEventsForCanvas([
            event(0, 638), event(33_333, 650, false), event(66_666, -10, false), event(99_999, 10, false)
        ], sourceSize: CGSize(width: 640, height: 400))
        let canvas = cursorTimeline(canvasEvents, durationUs: 100_000)
        assert(canvas.contains { $0.point.x == 650 && $0.visible }, "Legacy right-edge movement must render over the background")
        assert(canvas.contains { $0.point.x == -10 && $0.visible }, "Negative source coordinates must remain visible on the canvas")
        assert(canvas.last?.visible == false, "Preserve an explicitly hidden cursor inside the window")

        let late = cursorTimeline([event(20_000, 10)], durationUs: 100_000)
        assert(!late[0].visible && !late[1].visible && late[2].visible, "A late first observation must not become visible early")
        let invalid = cursorTimeline([event(-1, 0), event(0, 10), event(0, 20), event(30_000, .nan), event(120_000, 40)], durationUs: 100_000)
        assert(invalid.count == 2 && invalid.first?.point.x == 10, "Reject invalid, duplicate and out-of-duration samples")
        for frames in [dense, sparse, visibility, late, invalid] {
            assert(zip(frames, frames.dropFirst()).allSatisfy { $0.timeUs < $1.timeUs }, "Animation key times must increase strictly")
        }
        var counter = CursorClickCounter()
        assert(!counter.observe(left: 100, right: 20).left, "First observation establishes a baseline, not a click")
        assert(counter.observe(left: 101, right: 20).left, "Detect even a short click that released between cursor polls")
        assert(!counter.observe(left: 101, right: 20).left, "Holding a button must not retrigger a bounce")
        assert(counter.observe(left: 101, right: 21).right)
        _ = counter.observe(left: .max, right: 21)
        assert(counter.observe(left: 0, right: 21).left, "Handle counter rollover")
        let click: [String: Any] = ["tUs":1_020_000,"clickUs":1_000_000,"click":true,"visible":true]
        let bounce = cursorBounceTimeline([click], durationUs: 2_000_000)
        assert(bounce.first?.scale == 1 && bounce.first { $0.timeUs == 1_000_000 }?.scale == 1)
        assert(abs(bounce.first { $0.timeUs == 1_050_000 }!.scale - 0.9) < 0.00001)
        assert(abs(bounce.first { $0.timeUs == 1_140_000 }!.scale - 1.03) < 0.00001)
        assert(bounce.first { $0.timeUs == 1_240_000 }?.scale == 1 && bounce.last?.scale == 1)
        assert(cursorBounceTimeline([["tUs":0,"click":true,"visible":false]], durationUs: 1_000_000).isEmpty)
        let rapid = cursorBounceTimeline([click, ["tUs":1_080_000,"click":true,"visible":true]], durationUs: 2_000_000)
        assert(rapid.allSatisfy { $0.scale >= 0.88 && $0.scale <= 1.04 })
        assert(zip(rapid, rapid.dropFirst()).allSatisfy { $0.timeUs < $1.timeUs })
        print("Cursor timing passed: continuous clock during idle frames, callback latency, exact sample positions, gap/visibility holds, and monotonic export keys.")
    }
}
