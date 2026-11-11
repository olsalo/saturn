import Foundation
import AVFoundation
@main struct CompactTest {
 static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[2])
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
  let tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
  let composition = AVMutableComposition()
  for track in tracks {
   let dest = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
   var range = try await track.load(.timeRange)
   // Drop fractional fixture tail samples before repeating at a 30fps boundary.
   if track.mediaType == .video {
    range.duration = CMTime(value: Int64(floor(range.duration.seconds * 30)), timescale: 30)
   }
   guard range.duration > .zero else { fatalError("Fixture track is empty") }
   var t = CMTime.zero
   let end = CMTime(seconds: 30, preferredTimescale: 60000)
   while t < end {
    let length = CMTimeMinimum(range.duration, end - t)
    try dest.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: track, at: t)
    t = t + length
   }
  }
  let input = root.appendingPathComponent("reference.mov")
  let exp = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
  try await exp.export(to: input, as: .mov)
  let output = root.appendingPathComponent("compact.mp4")
  let started = Date()
  try await encodeVideo(input: input, output: output, cancel: root.appendingPathComponent("cancel"), duration: 30) { _ in }
  try await alignExportAudioToVideo(url: output, cancel: root.appendingPathComponent("cancel"))
  try await validateVideoEnding(asset: AVURLAsset(url: output))
  let rendered = AVURLAsset(url: output)
  let video = try await rendered.loadTracks(withMediaType: .video).first!
  let size = try await video.load(.naturalSize)
  let length = try await rendered.load(.duration).seconds
  let audio = try await rendered.loadTracks(withMediaType: .audio)
  guard size.width <= 2560, size.height <= 1600, abs(length - 30) < 0.04 else { fatalError("Unexpected export dimensions/duration: \(size), \(length)s") }
  guard audio.count == tracks.filter({ $0.mediaType == .audio }).count else { fatalError("An audio track was dropped") }
  let bytes = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! NSNumber
  print("30-second quality export: \(bytes) bytes, \(String(format: "%.2f", Date().timeIntervalSince(started))) seconds")
 }
}
