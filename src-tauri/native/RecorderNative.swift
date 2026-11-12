import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import AVFoundation
import QuartzCore

enum NativeOutput {
    @TaskLocal static var reporter: (([String: Any]) -> Void)?
}
func printNative(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) {
        print(text); fflush(stdout)
    }
}
func emit(_ value: [String: Any]) {
    if let reporter = NativeOutput.reporter { reporter(value) } else { printNative(value) }
}
func recorderProcessID() -> pid_t {
#if SATURN_BRIDGE
    return getpid()
#else
    return getppid()
#endif
}

/// ScreenCaptureKit enumeration runs only after explicit Screen Recording consent.
func shareableContent() async throws -> SCShareableContent {
    guard SourceAuthorization.shared.canList else {
        throw failure("Allow Screen Recording in System Settings, then reopen Saturn or refresh the window list.")
    }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        SourceAuthorization.shared.setConfirmed(true)
        return content
    } catch {
        let reason = error as NSError
        if reason.domain == SCStreamErrorDomain && reason.code == SCStreamError.Code.userDeclined.rawValue {
            SourceAuthorization.shared.setConfirmed(false)
        }
        throw error
    }
}

func selectableWindow(_ window: SCWindow) -> Bool {
    window.windowLayer == 0 && window.isOnScreen && window.frame.width > 100 && window.frame.height > 80 &&
        window.owningApplication?.processID != recorderProcessID() &&
        window.owningApplication?.bundleIdentifier != "com.saturn.recorder"
}

/// Keep Saturn's panel off the captured area and provide a menu-bar stop.
@MainActor final class RecordingBar: NSObject {
    static let shared = RecordingBar()
    private var item: NSStatusItem?
    private var hiddenWindows: [NSWindow] = []
    private var stopAction: (() -> Void)?
    func begin(stop: @escaping () -> Void) {
        stopAction = stop
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Saturn recording")
        status.button?.title = " Stop"
        status.button?.toolTip = "Stop Saturn recording (⌃⌥⌘R)"
        status.button?.target = self; status.button?.action = #selector(stopRecording)
        item = status
        hiddenWindows = NSApp.windows.filter { $0.isVisible && !$0.isSheet }
        for window in hiddenWindows { window.orderOut(nil) }
    }
    @objc private func stopRecording() { stopAction?(); item?.button?.isEnabled = false }
    func end() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil; stopAction = nil
        for window in hiddenWindows { window.makeKeyAndOrderFront(nil) }
        hiddenWindows = []
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Activate the target app and raise the chosen window when Accessibility access is available.
@MainActor func activateSelectedWindow(_ window: SCWindow) {
    guard let owner = window.owningApplication,
          let app = NSRunningApplication(processIdentifier: owner.processID) else { return }
    app.activate(options: [.activateAllWindows])
    guard AXIsProcessTrusted() else { return }
    let application = AXUIElementCreateApplication(owner.processID)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return }
    for candidate in windows {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(candidate, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(candidate, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { continue }
        let frame = CGRect(origin: position, size: size)
        if abs(frame.minX - window.frame.minX) < 2 && abs(frame.minY - window.frame.minY) < 2 &&
            abs(frame.width - window.frame.width) < 2 && abs(frame.height - window.frame.height) < 2 {
            AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
            break
        }
    }
}

func failure(_ message: String) -> NSError { NSError(domain: "Saturn", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
func json(_ path: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw failure("Invalid native request") }
    return object
}
func thumbnail(_ url: URL, destination: URL) async throws {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 600)
    let image = try await generator.image(at: .zero).image
    let bitmap = NSBitmapImageRep(cgImage: image)
    if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) { try data.write(to: destination) }
}

/// The stream supplies system and microphone samples independently. Store each
/// with its own first timestamp so it can be aligned to the captured video.
final class SeparateAudioWriter {
    let url: URL
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var firstTimeUs: Int64?
    init(url: URL) { self.url = url }
    func append(_ sample: CMSampleBuffer) throws {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric, let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        if writer == nil {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.pointee.mSampleRate,
                AVNumberOfChannelsKey: Int(asbd.pointee.mChannelsPerFrame), AVEncoderBitRateKey: 128_000]
            let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            newInput.expectsMediaDataInRealTime = true
            guard newWriter.canAdd(newInput) else { throw failure("Could not prepare separate audio recording") }
            newWriter.add(newInput)
            guard newWriter.startWriting() else { throw newWriter.error ?? failure("Could not start separate audio recording") }
            newWriter.startSession(atSourceTime: timestamp)
            firstTimeUs = CMTimeConvertScale(timestamp, timescale: 1_000_000, method: .roundTowardZero).value
            writer = newWriter; input = newInput
        }
        guard let input, input.isReadyForMoreMediaData else { throw failure("Separate audio recording could not keep up") }
        guard input.append(sample) else { throw writer?.error ?? failure("Could not write separate audio") }
    }
    func finish() async throws {
        guard let writer, let input else { return }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? failure("Could not finish separate audio") }
    }
}

@available(macOS 15.0, *)
final class Capture: NSObject, SCRecordingOutputDelegate, SCStreamOutput, SCStreamDelegate {
    let lock = NSLock()
    var started = false
    var finished = false
    var error: Error?
    var clock = CursorClock()
    var latestCursorObservation: CursorObservation?
    var frame: CGRect = .zero
    var dimensions: CGSize = .zero
    var cursorAssets: [String: CursorAsset] = [:]
    var cursorObservationPending = false
    var cursorAssetBytes = 0
    var clickCounter = CursorClickCounter()
    let cursor: FileHandle
    var systemAudio: SeparateAudioWriter?
    var microphoneAudio: SeparateAudioWriter?
    let report = NativeOutput.reporter ?? printNative
    init(cursor: FileHandle) { self.cursor = cursor }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); started = true; lock.unlock()
        report(["type":"started"])
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); finished = true; lock.unlock()
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); self.error = error; finished = true; lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); self.error = error; lock.unlock()
    }
    func fail(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
    func hasStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return started }
    func status() -> (Bool, Error?) { lock.lock(); defer { lock.unlock() }; return (finished, error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .audio || type == .microphone {
            do { try (type == .audio ? systemAudio : microphoneAudio)?.append(sampleBuffer) }
            catch { fail(error) }
            return
        }
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        anchorCursor(videoPTSUs: CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundTowardZero).value)
    }
    func anchorCursor(videoPTSUs origin: Int64) {
        let firstFrame = clock.originUs == nil
        clock.anchor(videoPTSUs: origin)
        if firstFrame, let observation = latestCursorObservation,
           let t = clock.timestamp(hostUs: origin) {
            // Carry the startup cursor state onto the first video frame. Later
            // observations retain their actual host timestamps.
            writeCursor(observation, at: t)
        }
    }
    // Called by the continuous sampler on the same serial queue as frame output.
    // A static screen produces no complete frames when showsCursor is false.
    func sampleCursor(_ observation: CursorObservation) {
        latestCursorObservation = observation
        guard let t = clock.timestamp(hostUs: observation.hostUs) else { return }
        writeCursor(observation, at: t)
    }
    private func writeCursor(_ observation: CursorObservation, at t: Int64) {
        let point = observation.point
        let x = frame.width > 0 ? (point.x - frame.minX) * dimensions.width / frame.width : 0
        let y = frame.height > 0 ? (point.y - frame.minY) * dimensions.height / frame.height : 0
        var event: [String: Any] = ["tUs":t,"type":"move","x":x,"y":y,"visible":true,
            "transform":["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height]]
        let changed = clickCounter.observe(left: observation.leftClicks, right: observation.rightClicks)
        if changed.left || changed.right {
            let ages = [changed.left ? observation.leftClickAge : nil, changed.right ? observation.rightClickAge : nil].compactMap { $0 }
            if let age = ages.filter({ $0.isFinite && $0 >= 0 && $0 < 1 }).min() {
                event["click"] = true
                event["clickUs"] = max(0, t - Int64(age * 1_000_000))
            }
        }
        if let asset = observation.asset {
            let id = asset.identifier
            if cursorAssets[id] != nil || (cursorAssets.count < 256 && cursorAssetBytes + asset.png.count < 10_000_000) {
                if cursorAssets[id] == nil { cursorAssetBytes += asset.png.count }
                cursorAssets[id] = asset
                event["cursorID"] = id
            }
        }
        event["cursorScaleX"] = dimensions.width / frame.width
        event["cursorScaleY"] = dimensions.height / frame.height
        if let data = try? JSONSerialization.data(withJSONObject: event) {
            do { try cursor.write(contentsOf: data + Data([10])) }
            catch { fail(error) }
        }
    }
}

@available(macOS 15.0, *)
func configureCaptureColors(_ config: SCStreamConfiguration) {
    // SCRecordingOutput writes Rec.709 video tags. Convert the display pixels
    // into the matching Core Media space before encoding, rather than leaving
    // them in the display profile (often P3). sRGB and itur_709 have different
    // transfer curves and also shift colors when interpreted with these tags.
    config.colorSpaceName = CGColorSpace.coreMedia709
}

@available(macOS 15.0, *)
func record(_ request: [String: Any]) async throws {
    guard let work = request["workspace"] as? String, let source = request["source"] as? [String: Any], let id = source["id"] as? String else { throw failure("Missing capture source") }
    guard let kind = source["kind"] as? String, let sourceID = UInt32(id), sourceID > 0 else {
        throw failure("Choose a window or screen before recording.")
    }
    let content = try await shareableContent()
    let selected: SCWindow?
    let display: SCDisplay
    if kind == "window" {
        guard let window = content.windows.first(where: { $0.windowID == sourceID && selectableWindow($0) }) else {
            throw failure("The selected window is no longer visible. Choose it again.")
        }
        guard let target = content.displays.first(where: { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(window.frame) }) else {
            throw failure("Keep the whole selected window on one display, then try again.")
        }
        selected = window
        display = target
    } else if kind == "display", let target = content.displays.first(where: { $0.displayID == sourceID }) {
        selected = nil
        display = target
    } else {
        throw failure("The selected screen is no longer available. Choose it again.")
    }
    let frame = selected?.frame ?? display.frame
    // Recordly's approach: a display filter cropped to the selected window.
    // No SCContentSharingPicker or single-window filter, so macOS does not
    // replace the target's traffic-light buttons with window-sharing controls.
    let excluded = content.applications.filter { $0.processID == recorderProcessID() || $0.bundleIdentifier == "com.saturn.recorder" }
    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    let config = SCStreamConfiguration()
    configureCaptureColors(config)
    let scale = CGFloat(filter.pointPixelScale)
    config.width = max(2, Int(frame.width * scale) / 2 * 2)
    config.height = max(2, Int(frame.height * scale) / 2 * 2)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 6
    config.showsCursor = false
    config.capturesAudio = request["systemAudio"] as? Bool ?? true
    config.excludesCurrentProcessAudio = true
    config.captureMicrophone = request["microphone"] as? Bool ?? false
    if config.captureMicrophone {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        if !allowed { throw failure("Microphone access was denied. Allow Saturn access in System Settings → Privacy & Security → Microphone.") }
    }
    let area = try selected == nil
        ? CaptureArea.display(display.frame, scale: scale)
        : CaptureArea.window(frame, on: display.frame, scale: scale)
    config.sourceRect = area.sourceRect
    config.width = area.pixelWidth; config.height = area.pixelHeight
    config.preservesAspectRatio = false
    config.destinationRect = CGRect(x: 0, y: 0, width: area.pixelWidth, height: area.pixelHeight)
    let cursorURL = URL(fileURLWithPath: work).appendingPathComponent("cursor/events.jsonl")
    FileManager.default.createFile(atPath: cursorURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: cursorURL)
    defer { try? handle.close() }
    let capture = Capture(cursor: handle)
    capture.frame = area.globalFrame; capture.dimensions = CGSize(width: config.width, height: config.height)
    let stream = SCStream(filter: filter, configuration: config, delegate: capture)
    let sampleQueue = DispatchQueue(label: "saturn.cursor")
    try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: sampleQueue)
    if config.capturesAudio {
        capture.systemAudio = SeparateAudioWriter(url: URL(fileURLWithPath: work + "/media/system.m4a"))
        try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: sampleQueue)
    }
    if config.captureMicrophone {
        capture.microphoneAudio = SeparateAudioWriter(url: URL(fileURLWithPath: work + "/media/microphone.m4a"))
        try stream.addStreamOutput(capture, type: .microphone, sampleHandlerQueue: sampleQueue)
    }
    let cursorTimer = DispatchSource.makeTimerSource(queue: sampleQueue)
    cursorTimer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
    let observations = DispatchGroup()
    cursorTimer.setEventHandler {
        guard !capture.cursorObservationPending else { return }
        capture.cursorObservationPending = true
        observations.enter()
        Task { @MainActor in
            let observation = CursorObservation.current()
            sampleQueue.async {
                if let observation { capture.sampleCursor(observation) }
                capture.cursorObservationPending = false
                observations.leave()
            }
        }
    }
    cursorTimer.resume()
    defer {
        cursorTimer.cancel()
        sampleQueue.sync { }
        observations.wait()
    }
    let outputConfig = SCRecordingOutputConfiguration()
    let mediaURL = URL(fileURLWithPath: work).appendingPathComponent("media/source.mov")
    outputConfig.outputURL = mediaURL; outputConfig.outputFileType = .mov; outputConfig.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: outputConfig, delegate: capture)
    try stream.addRecordingOutput(output)
    await RecordingBar.shared.begin {
        do { try Data().write(to: URL(fileURLWithPath: work + "/stop")) }
        catch { capture.fail(error) }
    }
    defer { Task { @MainActor in RecordingBar.shared.end() } }
    if let selected { await activateSelectedWindow(selected) }
    // Establish a cursor state before video can arrive, even if the timer's
    // first main-actor observation has not completed yet.
    if let initialCursor = await MainActor.run(body: { CursorObservation.current() }) {
        sampleQueue.sync { capture.sampleCursor(initialCursor) }
    }
    try await stream.startCapture()
    let start = Date()
    let owner = getppid()
    var lastFrame = area.globalFrame
    while !FileManager.default.fileExists(atPath: work + "/stop") {
        if getppid() != owner || Date().timeIntervalSince(start) >= 86_399 { break }
        if capture.status().1 != nil { break }
        if let selected { do {
            guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, selected.windowID) as? [[String: Any]],
                  let info = entries.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let current = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                throw failure("The selected window closed or was minimized. Captured footage was kept.")
            }
            let area = try CaptureArea.window(current, on: display.frame, scale: scale)
            if area.globalFrame != lastFrame {
                config.sourceRect = area.sourceRect
                // Keep the source file dimensions fixed while following move/resize.
                try await stream.updateConfiguration(config)
                sampleQueue.sync { capture.frame = area.globalFrame }
                lastFrame = area.globalFrame
            }
        } catch { capture.fail(error); break } }
        if Date().timeIntervalSince(start) > 15 && !capture.hasStarted() {
            capture.fail(failure("Capture did not start. Refresh the source list and choose it again.")); break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    // Even on a stream failure, give the recording output a chance to finalize.
    try? await stream.stopCapture()
    cursorTimer.cancel()
    sampleQueue.sync { }
    observations.wait()
    for _ in 0..<300 {
        if capture.status().0 { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    let status = capture.status()
    guard status.0 else { throw failure("Recording finalization timed out. Source media retained for recovery.") }
    try handle.synchronize()
    try JSONEncoder().encode(capture.cursorAssets).write(to: URL(fileURLWithPath: work + "/cursor/assets.json"), options: .atomic)
    try await capture.systemAudio?.finish()
    try await capture.microphoneAudio?.finish()
    let asset = AVURLAsset(url: mediaURL)
    let duration = try await asset.load(.duration)
    try? await thumbnail(mediaURL, destination: URL(fileURLWithPath: work + "/preview/thumbnail.jpg"))
    var result: [String: Any] = ["type":"finished","durationUs":Int64(duration.seconds * 1_000_000),"width":config.width,"height":config.height]
    guard let origin = capture.clock.originUs else { throw failure("The recording has no video timestamp; captured files were retained.") }
    func audioInfo(_ writer: SeparateAudioWriter?, path: String) -> Any {
        guard let first = writer?.firstTimeUs else { return NSNull() }
        return ["path":path, "offsetUs":first - origin] as [String: Any]
    }
    result["separateAudio"] = ["system":audioInfo(capture.systemAudio, path:"media/system.m4a"),
                               "microphone":audioInfo(capture.microphoneAudio, path:"media/microphone.m4a")]
    if let error = status.1 { result["warning"] = "Capture stopped unexpectedly: " + error.localizedDescription + " The recording was saved." }
    emit(result)
}

func runNative(command: String, arguments: [String]) async throws {
            switch command {
            case "permissions":
                var status = SourceAuthorization.shared.status
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                status["microphone"] = micStatus == .authorized
                status["microphoneCanRequest"] = micStatus == .notDetermined
                emit(status)
            case "sources":
                guard SourceAuthorization.shared.canList else {
                    emit(["sources":[], "permissionRequired":true, "needsRestart":SourceAuthorization.shared.status["needsRestart"] ?? false]); return
                }
                let content: SCShareableContent
                do { content = try await shareableContent() }
                catch {
                    if !SourceAuthorization.shared.canList {
                        emit(["sources":[], "permissionRequired":true, "needsRestart":SourceAuthorization.shared.status["needsRestart"] ?? false]); return
                    }
                    throw error
                }
                let displays: [[String: Any]] = content.displays.enumerated().map { index, display in
                    ["kind":"display", "id":String(display.displayID),
                     "label":content.displays.count == 1 ? "Full screen" : "Screen \(index + 1)",
                     "application":"Full screen",
                     "primary":content.displays.count > 1 && display.displayID == CGMainDisplayID()]
                }
                let windows: [[String: Any]] = content.windows.filter(selectableWindow).sorted {
                    let lhs = ($0.owningApplication?.applicationName ?? "") + ($0.title ?? "")
                    let rhs = ($1.owningApplication?.applicationName ?? "") + ($1.title ?? "")
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }.map {
                    ["kind":"window", "id":String($0.windowID),
                     "label":$0.title?.isEmpty == false ? $0.title! : ($0.owningApplication?.applicationName ?? "Untitled"),
                     "application":$0.owningApplication?.applicationName ?? "Application"]
                }
                emit(["sources":displays + windows,"permissionRequired":false])
            case "request-permission":
                _ = await SourceAuthorization.shared.requestOnce()
                emit(SourceAuthorization.shared.status)
            case "request-microphone-permission":
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                emit(["microphone":allowed, "microphoneCanRequest":AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined])
            case "open-microphone-settings":
                await MainActor.run {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                }
                emit(["ok":true])
            case "open-file-settings":
                await MainActor.run {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
                }
                emit(["ok":true])
            case "open-screen-settings":
                await MainActor.run {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
                emit(["ok":true])
            case "record":
                if #available(macOS 15.0, *) { try await record(json(arguments[0])) } else { throw failure("macOS 15 or later is required") }
            case "export": try await exportVideo(json(arguments[0]))
            case "inspect":
                let url = URL(fileURLWithPath: arguments[0]); let asset = AVURLAsset(url: url)
                guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No recoverable video track") }
                let size = try await video.load(.naturalSize); let duration = try await asset.load(.duration)
                if arguments.count > 1 { try await thumbnail(url, destination: URL(fileURLWithPath: arguments[1])) }
                let descriptions = try await video.load(.formatDescriptions)
                let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                let fps = try await video.load(.nominalFrameRate)
                var bitDepth = 8
                var profile = 0
                if let description = descriptions.first, let extensions = CMFormatDescriptionGetExtensions(description) {
                    let dictionary = extensions as NSDictionary
                    if let atoms = dictionary["SampleDescriptionExtensionAtoms"] as? NSDictionary,
                       let data = atoms["hvcC"] as? Data, data.count > 18 {
                        bitDepth = Int(data[17] & 7) + 8
                        profile = Int(data[1] & 31)
                    }
                }
                emit(["durationUs":Int64(duration.seconds*1_000_000),"width":Int(size.width),"height":Int(size.height),"hasAudio": !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,"codec":codec,"fps":fps,"bitDepth":bitDepth,"hevcProfile":profile])
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: arguments[0])]); emit(["ok":true])
            case "copy-file": NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([URL(fileURLWithPath: arguments[0]) as NSURL]); emit(["ok":true])
            case "copy-path": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(arguments[0], forType: .string); emit(["ok":true])
            default: throw failure("Unknown native command")
            }
}

#if SATURN_BRIDGE
public typealias NativeCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private final class BridgeReporter {
    private let lock = NSLock()
    private var active = true
    private let callback: NativeCallback
    private let context: UnsafeMutableRawPointer?
    init(context: UnsafeMutableRawPointer?, callback: @escaping NativeCallback) { self.context = context; self.callback = callback }
    func send(_ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        if let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) {
            text.withCString { callback($0, context) }
        }
    }
    func close() { lock.lock(); active = false; lock.unlock() }
}
@_cdecl("saturn_native_run")
public func saturnNativeRun(_ request: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?, _ callback: NativeCallback) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    let input = String(cString: request)
    let reporter = BridgeReporter(context: context, callback: callback)
    let report: ([String: Any]) -> Void = { reporter.send($0) }
    Task {
        await NativeOutput.$reporter.withValue(report) {
            do {
                guard let bytes = input.data(using: .utf8),
                      let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let command = request["command"] as? String,
                      let arguments = request["arguments"] as? [String] else { throw failure("Invalid native bridge request") }
                try await runNative(command: command, arguments: arguments)
            } catch {
                status = 1
                let reason = error as NSError
                report(["type":"error", "message":error.localizedDescription, "domain":reason.domain, "code":reason.code])
            }
        }
        reporter.close()
        semaphore.signal()
    }
    // Rust calls this only on a background worker; AppKit's main loop stays free.
    semaphore.wait()
    return status
}
#else
@main struct Native {
    static func main() async {
        _ = NSApplication.shared
        do {
            guard CommandLine.arguments.count >= 2 else { throw failure("Missing command") }
            try await runNative(command: CommandLine.arguments[1], arguments: Array(CommandLine.arguments.dropFirst(2)))
        } catch { emit(["type":"error","message":error.localizedDescription]); exit(1) }
    }
}
#endif
