import Foundation
import CoreGraphics

struct CursorKeyframe: Equatable {
    let timeUs: Int64
    let point: CGPoint
    let visible: Bool
    var cursorID: String = "arrow"
    var pixelScaleX: Double = 1
    var pixelScaleY: Double = 1
}

/// Older captures used `visible` to mean "hotspot inside the captured window".
/// Their outside coordinates are still recorded and can render on the canvas.
/// Preserve explicitly hidden observations within the window.
func cursorEventsForCanvas(_ events: [[String: Any]], sourceSize: CGSize) -> [[String: Any]] {
    events.map { event in
        var event = event
        if let x = event["x"] as? Double, let y = event["y"] as? Double,
           x.isFinite, y.isFinite,
           !CGRect(origin: .zero, size: sourceSize).contains(CGPoint(x: x, y: y)) {
            event["visible"] = true
        }
        return event
    }
}

/// Interpolate only adjacent samples. Missing history is not evidence that the
/// cursor travelled steadily across an idle interval. Never low-pass positions:
/// that delays the pointer while tooltips and other captured UI remain on time.
func cursorTimeline(_ events: [[String: Any]], durationUs: Int64) -> [CursorKeyframe] {
    guard durationUs > 0 else { return [] }
    var frames: [CursorKeyframe] = []
    for event in events {
        guard let time = event["tUs"] as? NSNumber,
              let x = event["x"] as? Double, let y = event["y"] as? Double,
              x.isFinite, y.isFinite else { continue }
        let us = time.int64Value
        guard us >= 0, us <= durationUs else { continue }
        var next = CursorKeyframe(timeUs: us, point: CGPoint(x: x, y: y), visible: event["visible"] as? Bool == true)
        next.cursorID = event["cursorID"] as? String ?? "arrow"
        next.pixelScaleX = event["cursorScaleX"] as? Double ?? 1
        next.pixelScaleY = event["cursorScaleY"] as? Double ?? 1
        if let previous = frames.last {
            guard us > previous.timeUs else { continue }
            // Old recordings sampled only when screen content changed. Hold
            // rather than inventing motion through their long sampling gaps.
            if us - previous.timeUs > 1 && (us - previous.timeUs > 100_000 || next.visible != previous.visible) {
                frames.append(CursorKeyframe(timeUs: us - 1, point: previous.point, visible: previous.visible, cursorID: previous.cursorID, pixelScaleX: previous.pixelScaleX, pixelScaleY: previous.pixelScaleY))
            }
        } else if us > 0 {
            frames.append(CursorKeyframe(timeUs: 0, point: next.point, visible: false))
            if us > 1 { frames.append(CursorKeyframe(timeUs: us - 1, point: next.point, visible: false)) }
        }
        frames.append(next)
    }
    if let last = frames.last, last.timeUs < durationUs {
        frames.append(CursorKeyframe(timeUs: durationUs, point: last.point, visible: last.visible, cursorID: last.cursorID, pixelScaleX: last.pixelScaleX, pixelScaleY: last.pixelScaleY))
    }
    return frames
}

/// Convert a live cursor observation's host timestamp to the video PTS origin.
/// Timestamp the observation itself, not the earlier frame-delivery timestamp.
struct CursorClock {
    private(set) var originUs: Int64?
    private var previousUs: Int64 = -1
    mutating func anchor(videoPTSUs: Int64) {
        if originUs == nil { originUs = videoPTSUs }
    }
    mutating func timestamp(hostUs: Int64) -> Int64? {
        guard let originUs, hostUs >= originUs else { return nil }
        let elapsed = hostUs - originUs
        guard elapsed > previousUs else { return nil }
        previousUs = elapsed
        return elapsed
    }
}

struct CursorClickCounter {
    private var previous: (UInt32, UInt32)?
    mutating func observe(left: UInt32, right: UInt32) -> (left: Bool, right: Bool) {
        defer { previous = (left, right) }
        guard let previous else { return (false, false) }
        return (left != previous.0, right != previous.1)
    }
}

struct CursorBounceKeyframe {
    let timeUs: Int64
    let scale: Double
}

/// A small 240 ms pulse about the click hotspot: 10% press, 3% rebound.
/// Superimposing pulses keeps rapid clicks continuous rather than restarting
/// an animation at scale 1. No keyframe moves or changes the cursor hotspot.
func cursorBounceTimeline(_ events: [[String: Any]], durationUs: Int64) -> [CursorBounceKeyframe] {
    let clicks = events.compactMap { event -> Int64? in
        guard event["click"] as? Bool == true, event["visible"] as? Bool == true,
              let time = (event["clickUs"] ?? event["tUs"]) as? NSNumber else { return nil }
        let us = time.int64Value
        return us >= 0 && us < durationUs ? us : nil
    }.sorted()
    guard !clicks.isEmpty, durationUs > 0 else { return [] }
    let offsets: [Int64] = [0, 33_333, 50_000, 83_333, 116_667, 140_000, 173_333, 206_667, 240_000]
    var times: Set<Int64> = [0, durationUs]
    for click in clicks { for offset in offsets { times.insert(min(durationUs, click + offset)) } }
    func pulse(_ elapsed: Int64) -> Double {
        let a: Int64; let b: Int64; let from: Double; let to: Double
        switch elapsed {
        case 0..<50_000: (a,b,from,to) = (0,50_000,1,0.90)
        case 50_000..<140_000: (a,b,from,to) = (50_000,140_000,0.90,1.03)
        case 140_000..<240_000: (a,b,from,to) = (140_000,240_000,1.03,1)
        default: return 1
        }
        let t = Double(elapsed - a) / Double(b - a)
        return from + (to - from) * t * t * (3 - 2 * t)
    }
    var first = 0
    return times.sorted().map { time in
        while first < clicks.count && clicks[first] + 240_000 < time { first += 1 }
        var index = first; var scale = 1.0
        while index < clicks.count && clicks[index] <= time {
            scale += pulse(time - clicks[index]) - 1
            index += 1
        }
        return CursorBounceKeyframe(timeUs: time, scale: min(1.04, max(0.88, scale)))
    }
}
