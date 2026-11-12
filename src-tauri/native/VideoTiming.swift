import Foundation
import AVFoundation

/// A container can outlast its actual picture data (audio tails, empty edits,
/// ScreenCaptureKit end markers). Never ask the compositor for those frames.
func exportVideoTimeRange(asset: AVAsset, track: AVAssetTrack, frameRate: Int32 = 30) async throws -> CMTimeRange {
    let range = try await track.load(.timeRange)
    let assetDuration = try await asset.load(.duration)
    let limit = CMTimeMinimum(CMTimeRangeGetEnd(range), assetDuration)
    var pictureEnd: CMTime?
    if let cursor = track.makeSampleCursor(presentationTimeStamp: limit) {
        repeat {
            let pts = cursor.presentationTimeStamp
            if pts.isNumeric, cursor.currentSampleStorageRange.length > 0 {
                let duration = cursor.currentSampleDuration
                let end = duration.isNumeric && duration > .zero ? pts + duration : pts + CMTime(value: 1, timescale: frameRate)
                pictureEnd = CMTimeMinimum(end, limit)
                break
            }
        } while cursor.stepInPresentationOrder(byCount: -1) != 0
    }
    // Some formats cannot provide sample cursors. Inspect compressed samples;
    // this fallback does not decode full-resolution frames or retain media.
    if pictureEnd == nil {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? timingFailure("Could not read video samples") }
        while let sample = output.copyNextSampleBuffer() {
            let pts = sample.presentationTimeStamp
            guard pts.isNumeric, sample.numSamples > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            let duration = sample.duration
            let end = CMTimeMinimum(limit, pts + (duration.isNumeric && duration > .zero ? duration : CMTime(value: 1, timescale: frameRate)))
            pictureEnd = pictureEnd.map { CMTimeMaximum($0, end) } ?? end
        }
        if reader.status == .failed { throw reader.error ?? timingFailure("Could not read video samples") }
    }
    guard let end = pictureEnd, end.isNumeric, end > .zero else { throw timingFailure("Source has no displayable video frames") }
    // A stored sample can still decode to black/transparent pixels (for example
    // a capture shutdown frame). Check picture data, not just its byte count.
    let visibleEnd = try await lastVisibleVideoEnd(asset: asset, track: track, limit: end, frameRate: frameRate)
    // A fractional trailing interval otherwise rounds up to an output frame
    // beyond the picture coverage. Retain complete frames, never round up.
    let aligned = CMTimeConvertScale(visibleEnd, timescale: frameRate, method: .roundTowardZero)
    return CMTimeRange(start: .zero, duration: aligned > .zero ? aligned : visibleEnd)
}

/// Decode only the tail, expanding backwards for a longer empty ending. Keep
/// black frames inside the recording; only the terminal blank interval is cut.
private func lastVisibleVideoEnd(asset: AVAsset, track: AVAssetTrack, limit: CMTime, frameRate: Int32) async throws -> CMTime {
    var windowEnd = limit
    while windowEnd > .zero {
        let start = CMTimeMaximum(.zero, windowEnd - CMTime(seconds: 1, preferredTimescale: 600))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: windowEnd)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? timingFailure("Could not decode video ending") }
        var visibleEnd: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let pts = sample.presentationTimeStamp
            guard pts.isNumeric, let pixels = sample.imageBuffer,
                  CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_EmptyMedia, attachmentModeOut: nil) as? Bool != true,
                  !isBlankVideoFrame(pixels) else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            guard attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool != true else { continue }
            let duration = sample.duration
            let end = CMTimeMinimum(limit, pts + (duration.isNumeric && duration > .zero ? duration : CMTime(value: 1, timescale: frameRate)))
            visibleEnd = visibleEnd.map { CMTimeMaximum($0, end) } ?? end
        }
        guard reader.status == .completed else { throw reader.error ?? timingFailure("Could not decode video ending") }
        if let end = visibleEnd { return end }
        windowEnd = start
    }
    throw timingFailure("Source has no nonblank video frames")
}

/// BGRA buffers only. Allow codec noise near black without mistaking dark UI
/// with visible content for an empty frame. Scan every pixel, including alpha.
func isBlankVideoFrame(_ buffer: CVPixelBuffer) -> Bool {
    precondition(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<CVPixelBufferGetHeight(buffer) {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<CVPixelBufferGetWidth(buffer) {
            let p = x * 4
            if row[p + 3] > 0 && max(row[p], row[p + 1], row[p + 2]) > 8 { return false }
        }
    }
    return true
}

/// MP4 movie headers and track edits can use different timescales. A rounded
/// movie duration may exceed the video by up to one 600 Hz movie tick even
/// when the tracks end together. This is much shorter than a video frame.
func exceedsVideoEnd(_ candidate: CMTime, videoEnd: CMTime) -> Bool {
    candidate > videoEnd + CMTime(value: 1, timescale: 600)
}

/// Even a sub-frame overrun can make some players display black at the end.
func needsExportAlignment(_ candidate: CMTime, videoEnd: CMTime) -> Bool {
    candidate > videoEnd
}

/// AAC packet padding can outlast the picture even when its input was trimmed.
/// A passthrough export adds an exact presentation edit without re-encoding.
func alignExportAudioToVideo(url: URL, cancel: URL) async throws {
    // A passthrough edit can expose a slightly shorter video track than the
    // original MP4 reported. Reinspect the actual result before committing it.
    for _ in 0..<3 {
        if try await !alignExportAudioPass(url: url, cancel: cancel) { return }
    }
    let asset = AVURLAsset(url: url)
    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw timingFailure("Export has no video") }
    let end = CMTimeRangeGetEnd(try await video.load(.timeRange))
    guard !needsExportAlignment(try await asset.load(.duration), videoEnd: end) else { throw timingFailure("Could not align export audio to video") }
    for audio in try await asset.loadTracks(withMediaType: .audio) {
        guard !needsExportAlignment(CMTimeRangeGetEnd(try await audio.load(.timeRange)), videoEnd: end) else { throw timingFailure("Could not align export audio to video") }
    }
}

private func alignExportAudioPass(url: URL, cancel: URL) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw timingFailure("Export has no video") }
    let end = CMTimeRangeGetEnd(try await video.load(.timeRange))
    guard end.isNumeric, end > .zero else { throw timingFailure("Export has no video duration") }
    var needsTrim = needsExportAlignment(try await asset.load(.duration), videoEnd: end)
    for audio in try await asset.loadTracks(withMediaType: .audio) {
        if needsExportAlignment(CMTimeRangeGetEnd(try await audio.load(.timeRange)), videoEnd: end) { needsTrim = true }
    }
    guard needsTrim else { return false }
    let pending = url.deletingLastPathComponent().appendingPathComponent(".saturn-timing-" + UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: pending) }
    guard !FileManager.default.fileExists(atPath: cancel.path) else { throw timingFailure("Export cancelled") }
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw timingFailure("Could not align export audio") }
    exporter.timeRange = CMTimeRange(start: .zero, end: end)
    exporter.shouldOptimizeForNetworkUse = true
    exporter.outputURL = pending
    exporter.outputFileType = .mp4
    exporter.exportAsynchronously { }
    while exporter.status == .waiting || exporter.status == .exporting || exporter.status == .unknown {
        if FileManager.default.fileExists(atPath: cancel.path) { exporter.cancelExport() }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard !FileManager.default.fileExists(atPath: cancel.path) else { throw timingFailure("Export cancelled") }
    guard exporter.status == .completed else { throw exporter.error ?? timingFailure("Could not align export audio") }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: pending)
    return true
}

/// Inspect the actual last decoded sample, rather than asking an image generator
/// for a nominal timestamp which may precede an extra encoder frame.
func validateVideoEnding(asset: AVAsset) async throws {
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw timingFailure("Export has no video") }
    let range = try await track.load(.timeRange)
    let end = CMTimeRangeGetEnd(range)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTimeMaximum(range.start, end - CMTime(seconds: 1, preferredTimescale: 600)), end: end)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? timingFailure("Could not validate video ending") }
    var lastPTS = CMTime.invalid
    var lastSampleEnd = CMTime.invalid
    var visible = false
    while let sample = output.copyNextSampleBuffer() {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric, !lastPTS.isNumeric || pts >= lastPTS else { continue }
        lastPTS = pts
        let sampleDuration = sample.duration
        lastSampleEnd = sampleDuration.isNumeric && sampleDuration > .zero ? pts + sampleDuration : .invalid
        visible = sample.imageBuffer.map { !isBlankVideoFrame($0) } ?? false
    }
    guard reader.status == .completed, visible else { throw reader.error ?? timingFailure("Export ends with a blank frame") }
    if lastSampleEnd.isNumeric && exceedsVideoEnd(end, videoEnd: lastSampleEnd) {
        throw timingFailure("Export extends beyond its final video frame")
    }
    guard !exceedsVideoEnd(try await asset.load(.duration), videoEnd: end) else { throw timingFailure("Export extends beyond its final video frame") }
    for audio in try await asset.loadTracks(withMediaType: .audio) {
        guard !exceedsVideoEnd(CMTimeRangeGetEnd(try await audio.load(.timeRange)), videoEnd: end) else { throw timingFailure("Export audio extends beyond its final video frame") }
    }
}

private func timingFailure(_ message: String) -> NSError {
    NSError(domain: "Saturn", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
