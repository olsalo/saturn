import Foundation
import AVFoundation
import AppKit
/// Regression for the retained real compositor fixture documented in VALIDATION.md.
/// Compare radial outline contrast at its three inactive macOS window controls.
@main struct WindowControls {
 static func frame(_ path: String, size: CGSize) async throws -> NSBitmapImageRep {
  let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
  generator.maximumSize = size
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  return NSBitmapImageRep(cgImage: try await generator.image(at: .zero).image)
 }
 static func contrast(_ image: NSBitmapImageRep, x: Double, y: Double, angle: Double, scale: Double) -> Double {
  var darkest = 1.0
  for r in stride(from: 9.0, through: 17.0, by: 0.5) {
   let px = Int((x + cos(angle) * r * scale).rounded())
   let py = Int((y + sin(angle) * r * scale).rounded())
   let c = image.colorAt(x: px, y: py)!.usingColorSpace(.deviceRGB)!
   darkest = min(darkest, 0.2126*c.redComponent + 0.7152*c.greenComponent + 0.0722*c.blueComponent)
  }
  return 1-darkest
 }
 static func main() async throws {
  let output = CommandLine.arguments[2]
  let asset = AVURLAsset(url: URL(fileURLWithPath: output))
  let track = try await asset.loadTracks(withMediaType: .video).first!
  let size = try await track.load(.naturalSize)
  let a = try await frame(CommandLine.arguments[1], size: size)
  let b = try await frame(output, size: size)
  let scale = size.width / 3456
  var missing = 0, total = 0
  for cx in [308.0,352.0,396.0] {
   var localMissing=0
   for degrees in stride(from: 0, to: 360, by: 5) {
    let angle = Double(degrees) * .pi / 180
    let expected = contrast(a,x:cx*scale,y:203*scale,angle:angle,scale:scale)
    let actual = contrast(b,x:cx*scale,y:203*scale,angle:angle,scale:scale)
    if expected > 0.06 {
     total += 1
     if actual < expected * 0.5 { missing += 1;localMissing+=1 }
    }
   }
   print("circle \(cx): \(localMissing) missing arc samples")
  }
  guard total >= 120, missing <= total / 100 else {
   throw NSError(domain: "WindowControlsTest", code: 1, userInfo: [NSLocalizedDescriptionKey:
    "Window control outlines lost: \(missing)/\(total) sampled arc positions"])
  }
  print("Window control outlines passed: \(total - missing)/\(total) sampled arcs retained.")
 }
}
