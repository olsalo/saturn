import Foundation
import AppKit
import AVFoundation
import QuartzCore

func color(_ hex: String) -> CGColor {
    let n = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
    return CGColor(red: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255, blue: CGFloat(n & 255)/255, alpha: 1)
}
func exportVideo(_ request: [String: Any]) async throws {
    guard let work = request["workspace"] as? String, let output = request["output"] as? String else { throw failure("Missing render paths") }
    let encoder: ExportEncoder
    if let value = request["encoder"] {
        guard let name = value as? String, let selected = ExportEncoder(rawValue: name) else { throw failure("Unsupported export encoder") }
        // AV1 and VP9 are internal stages of the paired website export.
        guard selected != .av1 && selected != .vp9 else { throw failure("Select the website encoder to export AV1 with VP9 fallback") }
        encoder = selected
    } else {
        encoder = .defaultEncoder
    }
    try validateExportEncoder(encoder)
    let manifest = try (request["manifest"] as? [String: Any]) ?? json(work + "/manifest.json")
    if request["manifest"] == nil, let clips = manifest["clips"] as? [[String: Any]], !clips.isEmpty {
        try await exportSequence(request, manifest: manifest, clips: clips, encoder: encoder)
        return
    }
    let media = manifest["media"] as! [String: Any]
    let appearance = manifest["appearance"] as! [String: Any]
    let background = appearance["background"] as! [String: Any]
    let settings = manifest["export"] as! [String: Any]
    let asset = AVURLAsset(url: URL(fileURLWithPath: work + "/" + (media["path"] as! String)))
    guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw failure("Source has no video") }
    let configuredFPS = (settings["frameRate"] as? Int) ?? 60
    let sourceRate = media["frameRate"] as? [String: Any]
    let sourceFPS = Double(sourceRate?["numerator"] as? Int ?? 30) / Double(max(1, sourceRate?["denominator"] as? Int ?? 1))
    let renderFPS = min(configuredFPS, max(1, Int(sourceFPS.rounded())))
    let videoRange = try await exportVideoTimeRange(asset: asset, track: source, frameRate: Int32(renderFPS))
    let duration = videoRange.duration
    let composition = AVMutableComposition()
    let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try track.insertTimeRange(videoRange, of: source, at: .zero)
    if let separate = media["separateAudio"] as? [String: Any] {
        for (key, includeKey) in [("system", "includeSystemAudio"), ("microphone", "includeMicrophoneAudio")] {
            guard (settings[includeKey] as? Bool ?? true), let info = separate[key] as? [String: Any],
                  let path = info["path"] as? String else { continue }
            let audioAsset = AVURLAsset(url: URL(fileURLWithPath: work + "/" + path))
            guard let audio = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw failure("Missing recorded audio track") }
            let range = try await audio.load(.timeRange)
            let offset = CMTime(value: info["offsetUs"] as? Int64 ?? 0, timescale: 1_000_000)
            let trim = CMTimeMaximum(.zero, CMTimeSubtract(.zero, offset))
            let target = CMTimeMaximum(.zero, offset)
            let available = CMTimeMinimum(CMTimeSubtract(range.duration, trim), CMTimeSubtract(duration, target))
            guard available > .zero else { continue }
            let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try dest.insertTimeRange(CMTimeRange(start: CMTimeAdd(range.start, trim), duration: available), of: audio, at: target)
        }
    } else {
        // Legacy recordings contain a single mixed source track.
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            let audioRange = try await audio.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(audioRange, otherRange: videoRange)
            guard overlap.isValid, overlap.duration > .zero else { continue }
            let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try dest.insertTimeRange(overlap, of: audio, at: overlap.start)
        }
    }
    let size = CGSize(width: settings["width"] as! Int, height: settings["height"] as! Int)
    let natural = try await source.load(.naturalSize)
    let preferred = try await source.load(.preferredTransform)
    let rect = CGRect(origin: .zero, size: natural).applying(preferred)
    let none = background["type"] as? String == "none"
    let videoRect = exportVideoRect(source: CGSize(width: abs(rect.width), height: abs(rect.height)), canvas: size,
                                    paddingPercent: appearance["paddingPercent"] as? Double,
                                    paddingPixels: Double(appearance["paddingPx"] as? Int ?? 64), none: none)
    let scale = videoRect.width / abs(rect.width)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    let transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)).concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: videoRect.minX, y: videoRect.minY))
    layerInstruction.setTransform(transform, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration); instruction.layerInstructions = [layerInstruction]
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = size; videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(renderFPS)); videoComposition.instructions = [instruction]
    videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
    parent.backgroundColor = color("17191c")
    let bg = CAGradientLayer(); bg.frame = parent.bounds
    let preset = background["preset"] as? String ?? "dawn"
    let colors = preset == "dusk" ? ["6667ac","b894ba","edbdac"] : preset == "mint" ? ["224c4b","6a9f8c","d1dfb2"] : preset == "ink" ? ["1a1d24","424b5a","777d87"] : ["a2b5ee","d6bfde","f4c6ac"]
    bg.colors = colors.map { color($0) }; bg.startPoint = CGPoint(x: 0, y: 1); bg.endPoint = CGPoint(x: 1, y: 0)
    if background["type"] as? String == "solid" {
        parent.backgroundColor = color(background["color"] as? String == "black" ? "000000" : "ffffff")
    } else if !none { parent.addSublayer(bg) }
    if background["type"] as? String == "embeddedImage", let path = background["path"] as? String, let image = NSImage(contentsOfFile: work + "/" + path) {
        let imageLayer = CALayer(); imageLayer.frame = parent.bounds; imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil); imageLayer.contentsGravity = .resizeAspectFill; imageLayer.masksToBounds = true; parent.addSublayer(imageLayer)
    }
    var radius = none ? 0 : exportCornerRadius(CGFloat(appearance["cornerRadiusPx"] as! Int), canvasWidth: size.width)
    if !none && media["captureKind"] as? String != "display" {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: videoRange.start).image
        radius = max(radius, recordedCornerRadius(image) * videoRect.width / CGFloat(image.width))
    }
    let maskRect = none ? videoRect : exportVideoMaskRect(videoRect)
    if appearance["shadow"] as? Bool == true && !none {
        // Layered shadow profile at 20% intensity.
        for (offset, blur, opacity) in [(2.4, 9.6, 0.14), (0.8, 3.2, 0.10), (0.4, 1.6, 0.06)] {
            let shadow = CALayer(); shadow.frame = maskRect
            shadow.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shadow.shadowOpacity = Float(opacity); shadow.shadowRadius = CGFloat(blur); shadow.shadowOffset = CGSize(width: 0, height: -offset)
            parent.addSublayer(shadow)
        }
    }
    let video = CALayer(); video.frame = parent.bounds
    let mask = CAShapeLayer(); mask.path = CGPath(roundedRect: maskRect, cornerWidth: radius, cornerHeight: radius, transform: nil); video.mask = mask
    parent.addSublayer(video)
    if let data = try? String(contentsOfFile: work + "/" + ((manifest["cursor"] as? [String: Any])?["path"] as? String ?? "cursor/events.jsonl"), encoding: .utf8) {
        let events = data.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        let cursor = CALayer()
        var assets = (try? Data(contentsOf: URL(fileURLWithPath: work + "/" + ((((manifest["cursor"] as? [String: Any])?["path"] as? String ?? "cursor/events.jsonl") as NSString).deletingLastPathComponent) + "/assets.json"))).flatMap { try? JSONDecoder().decode([String: CursorAsset].self, from: $0) } ?? [:]
        if let arrow = await CursorAsset.system(.arrow) { assets["arrow"] = arrow }
        let positions = CAKeyframeAnimation(keyPath: "position")
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        var points: [NSValue] = []; var times: [NSNumber] = []; var opacities: [NSNumber] = []
        let smooth = appearance["cursorSmoothing"] as? Bool ?? true
        let scaledEvents = cursorEventsForCanvas(events, sourceSize: CGSize(width: media["width"] as! Int, height: media["height"] as! Int)).map { event -> [String: Any] in
            var event = event
            if let transform = event["transform"] as? [String: Any] {
                if event["cursorScaleX"] == nil, let width = transform["width"] as? Double, width > 0 {
                    event["cursorScaleX"] = Double(media["width"] as! Int) / width
                }
                if event["cursorScaleY"] == nil, let height = transform["height"] as? Double, height > 0 {
                    event["cursorScaleY"] = Double(media["height"] as! Int) / height
                }
            }
            return event
        }
        let keyframes = cursorTimeline(scaledEvents, durationUs: Int64(duration.seconds * 1_000_000))
        for frame in keyframes {
            let t = Double(frame.timeUs) / 1_000_000 / duration.seconds
            points.append(NSValue(point: CGPoint(x: videoRect.minX + frame.point.x * videoRect.width / Double(media["width"] as! Int), y: videoRect.maxY - frame.point.y * videoRect.height / Double(media["height"] as! Int))))
            times.append(NSNumber(value: t)); opacities.append(NSNumber(value: frame.visible ? 1 : 0))
        }
        if let first = points.first, let last = points.last {
            if times.first!.doubleValue > 0 { times.insert(0, at: 0); points.insert(first, at: 0); opacities.insert(0, at: 0) }
            if times.last!.doubleValue < 1 { times.append(1); points.append(last); opacities.append(0) }
            positions.values = points; positions.keyTimes = times; positions.calculationMode = smooth ? .linear : .discrete
            visibility.values = opacities; visibility.keyTimes = times; visibility.calculationMode = .discrete
            for animation in [positions, visibility] { animation.duration = duration.seconds; animation.beginTime = AVCoreAnimationBeginTimeAtZero; animation.isRemovedOnCompletion = false; animation.fillMode = .both }
            for id in Set(keyframes.map { $0.cursorID }) {
                guard let asset = assets[id] ?? assets["arrow"], let image = asset.cgImage else { continue }
                let sprite = CALayer(); sprite.contents = image
                sprite.contentsGravity = .resize; sprite.anchorPoint = .zero
                let geometry = CAKeyframeAnimation(keyPath: "bounds")
                let placement = CAKeyframeAnimation(keyPath: "position")
                let shown = CAKeyframeAnimation(keyPath: "opacity")
                var bounds: [NSValue] = []; var offsets: [NSValue] = []; var visible: [NSNumber] = []
                for frame in keyframes {
                    let rect = cursorSpriteRect(asset: asset,
                        pixelScaleX: frame.pixelScaleX * videoRect.width / Double(media["width"] as! Int),
                        pixelScaleY: frame.pixelScaleY * videoRect.height / Double(media["height"] as! Int))
                    bounds.append(NSValue(rect: CGRect(origin: .zero, size: rect.size)))
                    offsets.append(NSValue(point: rect.origin))
                    visible.append(NSNumber(value: frame.cursorID == id ? 1 : 0))
                }
                geometry.values = bounds; placement.values = offsets; shown.values = visible
                for animation in [geometry, placement, shown] {
                    animation.keyTimes = times; animation.calculationMode = .discrete
                    animation.duration = duration.seconds; animation.beginTime = AVCoreAnimationBeginTimeAtZero
                    animation.isRemovedOnCompletion = false; animation.fillMode = .both
                }
                sprite.add(geometry, forKey: "size"); sprite.add(placement, forKey: "hotspot"); sprite.add(shown, forKey: "shape")
                cursor.addSublayer(sprite)
            }
            if appearance["clickAnimation"] as? Bool == true {
                let bounce = cursorBounceTimeline(events, durationUs: Int64(duration.seconds * 1_000_000))
                if !bounce.isEmpty {
                    let animation = CAKeyframeAnimation(keyPath: "transform.scale")
                    animation.values = bounce.map { NSNumber(value: $0.scale) }
                    animation.keyTimes = bounce.map { NSNumber(value: Double($0.timeUs) / 1_000_000 / duration.seconds) }
                    animation.calculationMode = .linear
                    animation.duration = duration.seconds; animation.beginTime = AVCoreAnimationBeginTimeAtZero
                    animation.isRemovedOnCompletion = false; animation.fillMode = .both
                    cursor.add(animation, forKey: "click-bounce")
                }
            }
            cursor.add(positions, forKey: "position"); cursor.add(visibility, forKey: "visibility")
            // Cursor sprites and click animations may extend over the background.
            // Only the final video canvas bounds should clip them.
            parent.addSublayer(cursor)
        }
    }
    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    let renderOnly = request["renderOnly"] as? Bool ?? false
    let intermediate = renderOnly ? URL(fileURLWithPath: output) : URL(fileURLWithPath: work).appendingPathComponent("render-" + UUID().uuidString + ".mov")
    defer { if !renderOnly { try? FileManager.default.removeItem(at: intermediate) } }
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleProRes422LPCM) else { throw failure("Compositor encoder unavailable") }
    exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
    let audioTracks = composition.tracks(withMediaType: .audio)
    if audioTracks.count > 1 {
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
        exporter.audioMix = mix
    }
    exporter.videoComposition = videoComposition; exporter.outputURL = intermediate; exporter.outputFileType = .mov; exporter.shouldOptimizeForNetworkUse = false
    exporter.exportAsynchronously { }
    while exporter.status == .waiting || exporter.status == .exporting || exporter.status == .unknown {
        if FileManager.default.fileExists(atPath: work + "/cancel-export") { exporter.cancelExport() }
        emit(["type":"progress","fraction":Double(exporter.progress) * 0.4])
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    guard exporter.status == .completed else { throw exporter.error ?? failure("Export cancelled") }
    if renderOnly { return }
    // Core Animation/compositor output can itself have an empty terminal frame.
    // Bound the final encode to real rendered pictures as well as source data.
    let master = AVURLAsset(url: intermediate)
    guard let masterTrack = try await master.loadTracks(withMediaType: .video).first else { throw failure("Rendered video is missing") }
    let masterRange = try await exportVideoTimeRange(asset: master, track: masterTrack, frameRate: Int32(renderFPS))
    if encoder == .web {
        try await encodeWebsite(input: intermediate, folder: URL(fileURLWithPath: output),
                                cancel: URL(fileURLWithPath: work + "/cancel-export"), duration: masterRange.duration.seconds,
                                report: NativeOutput.reporter ?? printNative)
    } else {
        try await encodeVideo(input: intermediate, output: URL(fileURLWithPath: output),
                                  cancel: URL(fileURLWithPath: work + "/cancel-export"), duration: masterRange.duration.seconds, encoder: encoder, report: NativeOutput.reporter ?? printNative)
        try await alignExportAudioToVideo(url: URL(fileURLWithPath: output), cancel: URL(fileURLWithPath: work + "/cancel-export"))
        let check = AVURLAsset(url: URL(fileURLWithPath: output))
        guard try await check.load(.duration).seconds > 0 else { throw failure("Export validation failed") }
        try await validateVideoEnding(asset: check)
    }
    emit(["type":"finished"])
}


/// Render each source independently so cursor smoothing, click animation and
/// audio offsets cannot bleed across a cut. Join losslessly, then encode once.
func exportSequence(_ request: [String: Any], manifest: [String: Any], clips: [[String: Any]], encoder: ExportEncoder) async throws {
    guard let work = request["workspace"] as? String, let output = request["output"] as? String,
          let sequence = manifest["sequence"] as? [[String: Any]], !sequence.isEmpty else { throw failure("Missing clip sequence") }
    let root = URL(fileURLWithPath: work)
    let cancel = root.appendingPathComponent("cancel-export")
    let report = NativeOutput.reporter ?? printNative
    var temporary: [URL] = []
    defer { for file in temporary { try? FileManager.default.removeItem(at: file) } }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw failure("Could not prepare sequence") }
    var position = CMTime.zero
    var audioTracks: [AVMutableCompositionTrack] = []
    for (index, entry) in sequence.enumerated() {
        if FileManager.default.fileExists(atPath: cancel.path) { throw failure("Export cancelled") }
        guard let id = entry["clipId"] as? String, let clip = clips.first(where: { $0["id"] as? String == id }) else { throw failure("Missing sequence clip") }
        var single = manifest
        single.removeValue(forKey: "clips"); single.removeValue(forKey: "sequence")
        single["media"] = clip["media"]; single["cursor"] = clip["cursor"]
        let master = root.appendingPathComponent("render-" + UUID().uuidString + ".mov")
        temporary.append(master)
        var child = request
        child["manifest"] = single; child["output"] = master.path; child["renderOnly"] = true
        try await NativeOutput.$reporter.withValue({ event in
            if let fraction = event["fraction"] as? Double {
                report(["type":"progress", "fraction":(Double(index) + fraction / 0.4) / Double(sequence.count) * 0.4])
            }
        }) { try await exportVideo(child) }
        let asset = AVURLAsset(url: master)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw failure("Rendered clip is missing") }
        let range = try await exportVideoTimeRange(asset: asset, track: source)
        try video.insertTimeRange(range, of: source, at: position)
        for (audioIndex, audio) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
            let overlap = CMTimeRangeGetIntersection(try await audio.load(.timeRange), otherRange: range)
            if overlap.isValid && overlap.duration > .zero {
                while audioTracks.count <= audioIndex {
                    guard let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw failure("Could not prepare sequence audio") }
                    audioTracks.append(dest)
                }
                try audioTracks[audioIndex].insertTimeRange(overlap, of: audio, at: CMTimeAdd(position, CMTimeSubtract(overlap.start, range.start)))
            }
        }
        position = CMTimeAdd(position, range.duration)
    }
    let joined = root.appendingPathComponent("render-" + UUID().uuidString + ".mov")
    temporary.append(joined)
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw failure("Could not join clips") }
    exporter.outputURL = joined; exporter.outputFileType = .mov
    exporter.timeRange = CMTimeRange(start: .zero, duration: position)
    exporter.exportAsynchronously { }
    while [.waiting, .exporting, .unknown].contains(exporter.status) {
        if FileManager.default.fileExists(atPath: cancel.path) { exporter.cancelExport() }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard exporter.status == .completed else { throw exporter.error ?? failure("Export cancelled") }
    if encoder == .web {
        try await encodeWebsite(input: joined, folder: URL(fileURLWithPath: output), cancel: cancel, duration: position.seconds, report: report)
    } else {
        try await encodeVideo(input: joined, output: URL(fileURLWithPath: output), cancel: cancel, duration: position.seconds, encoder: encoder, report: report)
        try await alignExportAudioToVideo(url: URL(fileURLWithPath: output), cancel: cancel)
        let check = AVURLAsset(url: URL(fileURLWithPath: output))
        guard try await check.load(.duration).seconds > 0 else { throw failure("Export validation failed") }
        try await validateVideoEnding(asset: check)
    }
    emit(["type":"finished"])
}
