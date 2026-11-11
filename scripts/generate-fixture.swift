import Foundation
import AVFoundation
import AppKit
@main struct Fixture {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let video=root.appendingPathComponent("fixture-video.mov")
  let writer=try AVAssetWriter(outputURL:video,fileType:.mov)
  let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:640,AVVideoHeightKey:400])
  let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:640,kCVPixelBufferHeightKey as String:400])
  writer.add(input);guard writer.startWriting() else {throw writer.error!};writer.startSession(atSourceTime:.zero)
  let blankTail = CommandLine.arguments.contains("--blank-tail")
  let videoEnd = CMTime(value: blankTail ? 2100 : 2015, timescale: 1000)
  for frame in 0..<(blankTail ? 63 : 61) {
   while !input.isReadyForMoreMediaData {try await Task.sleep(nanoseconds:1_000_000)}
   var buffer:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer);let pixel=buffer!;CVPixelBufferLockBaseAddress(pixel,[])
   let ctx=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:640,height:400,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue)!
   ctx.setFillColor(CGColor(red:0.96,green:0.96,blue:0.94,alpha:1));ctx.fill(CGRect(x:0,y:0,width:640,height:400))
   ctx.setFillColor(CGColor(red:0.2,green:0.35,blue:0.3,alpha:1));ctx.fill(CGRect(x:0,y:355,width:640,height:45));ctx.fill(CGRect(x:30+frame*4,y:80,width:120,height:180))
   // A tooltip-like marker appears exactly at 1s for export timing checks.
   if frame >= 30 { ctx.setFillColor(CGColor(red:1,green:0.3,blue:0.05,alpha:1));ctx.fill(CGRect(x:560,y:280,width:40,height:40)) }
   if blankTail && frame >= 60 { ctx.setFillColor(CGColor(gray:0,alpha:1));ctx.fill(CGRect(x:0,y:0,width:640,height:400)) }
   CVPixelBufferUnlockBaseAddress(pixel,[]);guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else {throw writer.error!}
  }
  writer.endSession(atSourceTime:videoEnd)
  input.markAsFinished();await writer.finishWriting();if let error=writer.error {throw error}
  let audioURL=root.appendingPathComponent("fixture-audio.caf");let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
  let audioFile=try AVAudioFile(forWriting:audioURL,settings:format.settings)
  let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:108000)!;buffer.frameLength=108000
  for i in 0..<108000 {buffer.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/48000)*0.1)}
  try audioFile.write(from:buffer)
  let composition=AVMutableComposition();let v=AVURLAsset(url:video);let a=AVURLAsset(url:audioURL)
  let vt=try await v.loadTracks(withMediaType:.video).first!;let at=try await a.loadTracks(withMediaType:.audio).first!
  try composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start:.zero,duration:videoEnd),of:vt,at:.zero)
  try composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:2.25,preferredTimescale:600)),of:at,at:.zero)
  let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough)!
  try await export.export(to:root.appendingPathComponent("source.mov"),as:.mov)
 }
}
