import Foundation
import AppKit

@main struct RecordingPauseTests {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw failure("Recording control timed out")
    }
    @MainActor static func main() async throws {
        guard #available(macOS 15.0, *) else { return }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saturn-pause-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("preview"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        // The same status control formats long recordings without wrapping minutes.
        RecordingBar.shared.begin(stop: {}, toggle: {})
        assert(RecordingBar.shared.stopButton?.title == " 00:00 Stop")
        RecordingBar.shared.update(mode: "paused", recordedDurationUs: 3_661_000_000)
        assert(RecordingBar.shared.stopButton?.title == " 1:01:01 Stop")
        RecordingBar.shared.end()
        let events = EventLog()
        let job = Task {
            try await NativeOutput.$reporter.withValue({ event in
                events.append(event)
                if event["type"] as? String == "continueRequested" {
                    // Simulate the panel acknowledging Continue after its countdown.
                    try? Data().write(to: root.appendingPathComponent("continue"))
                }
            }) {
                try await record(["workspace":root.path, "source":["kind":"window"]], captureClip: { request in
                    let work = request["workspace"] as! String
                    emit(["type":"started"])
                    while !FileManager.default.fileExists(atPath: root.path + "/pause") && !FileManager.default.fileExists(atPath: root.path + "/stop") {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try Data("original".utf8).write(to: URL(fileURLWithPath: work + "/media/source.mov"))
                    try Data().write(to: URL(fileURLWithPath: work + "/cursor/events.jsonl"))
                    emit(["type":"pausing"])
                    try await Task.sleep(nanoseconds: 80_000_000)
                    emit(["type":"finished", "durationUs":Int64(1_000_000), "width":640, "height":400])
                })
            }
        }
        try await waitFor { RecordingBar.shared.pauseButton?.isEnabled == true }
        assert(RecordingBar.shared.pauseButton?.title == " Pause")
        assert(RecordingBar.shared.pauseButton?.action != nil && RecordingBar.shared.stopButton?.action != nil, "Actions must be directly clickable")
        assert(!window.isVisible, "Hide the panel while recording")
        assert(RecordingBar.shared.stopButton?.title == " 00:00 Stop", "New recordings reset the timer")
        try await waitFor { RecordingBar.shared.stopButton?.title == " 00:01 Stop" }

        RecordingBar.shared.pauseButton!.performClick(nil)
        assert(RecordingBar.shared.pauseButton?.isEnabled == false, "Repeated pause must be unavailable")
        try await waitFor { RecordingBar.shared.pauseButton?.title == " Continue" }
        assert(window.isVisible, "Show the panel while paused")
        assert(RecordingBar.shared.stopButton?.title == " 00:01 Stop", "Paused timer uses completed clip duration")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        assert(RecordingBar.shared.stopButton?.title == " 00:01 Stop", "Paused time is excluded")
        assert(FileManager.default.fileExists(atPath: root.path + "/clips.json"), "Pause must checkpoint footage")
        let started = events.values.filter { $0["type"] as? String == "started" }.count
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(events.values.filter { $0["type"] as? String == "started" }.count == started, "Paused recording must not start another clip")
        RecordingBar.shared.pauseButton!.performClick(nil)
        try await waitFor { events.values.filter { $0["type"] as? String == "started" }.count == 2 && RecordingBar.shared.pauseButton?.isEnabled == true }
        assert(!window.isVisible, "Hide the panel again before resuming capture")
        RecordingBar.shared.pauseButton!.performClick(nil)
        try await waitFor { RecordingBar.shared.pauseButton?.title == " Continue" }
        assert(window.isVisible)
        assert(RecordingBar.shared.stopButton?.title == " 00:02 Stop", "Timer totals all completed clips")
        RecordingBar.shared.stopButton!.performClick(nil)
        try await job.value
        let finished = events.values.last { $0["type"] as? String == "finished" }!
        assert((finished["clips"] as? [[String: Any]])?.count == 2)
        assert(finished["durationUs"] as? Int64 == 2_000_000, "Paused wall time must not enter recorded duration")
        let startedEvents = events.values.filter { $0["type"] as? String == "started" }
        assert(startedEvents[1]["recordedDurationMs"] as? Int64 == 1000)
        assert(FileManager.default.fileExists(atPath: root.path + "/clips/0002/media/source.mov"))
        print("Recording controls passed: direct status buttons, paused window visibility, resume hiding, checkpointing, separate clips, timer and Stop while paused.")
    }
}
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []
    func append(_ value: [String: Any]) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return stored }
}
