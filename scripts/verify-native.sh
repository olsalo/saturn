#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -m)" in arm64) target=arm64;; x86_64) target=x86_64;; *) exit 1;; esac
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/saturn-smoke.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" scripts/generate-fixture.swift -o "$task_dir/fixture"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/RecorderNative.swift src-tauri/native/ExportCompositor.swift src-tauri/native/VideoTiming.swift src-tauri/native/ExportEncoder.swift src-tauri/native/FFmpegEncoder.swift src-tauri/native/CursorAppearance.swift src-tauri/native/CursorTimeline.swift src-tauri/native/CaptureGeometry.swift src-tauri/native/CapturePermission.swift -o "$task_dir/native"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CaptureGeometry.swift scripts/capture-geometry-tests.swift -o "$task_dir/geometry"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CapturePermission.swift scripts/capture-permission-tests.swift -o "$task_dir/permissions"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CursorTimeline.swift scripts/cursor-timing-tests.swift -o "$task_dir/cursor-timing"
"$task_dir/cursor-timing"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -D SATURN_BRIDGE -target "$target-apple-macosx15.0" src-tauri/native/RecorderNative.swift src-tauri/native/ExportCompositor.swift src-tauri/native/VideoTiming.swift src-tauri/native/ExportEncoder.swift src-tauri/native/FFmpegEncoder.swift src-tauri/native/CursorAppearance.swift src-tauri/native/CursorTimeline.swift src-tauri/native/CaptureGeometry.swift src-tauri/native/CapturePermission.swift scripts/cursor-startup-tests.swift -o "$task_dir/cursor-startup"
"$task_dir/cursor-startup"
"$task_dir/permissions"
"$task_dir/geometry"
"$task_dir/fixture" "$task_dir/media"
python3 scripts/prepare-smoke.py "$task_dir/media"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CursorAppearance.swift src-tauri/native/CursorTimeline.swift scripts/cursor-appearance-tests.swift -o "$task_dir/cursor-appearance"
"$task_dir/cursor-appearance" "$task_dir/media/cursor/assets.json"
"$task_dir/native" inspect "$task_dir/media/media/source.mov" > "$task_dir/source-inspection.json"
python3 - "$task_dir/source-inspection.json" <<'PYTAIL'
import json,sys
v=json.load(open(sys.argv[1]))
assert v['durationUs'] > 2200000, v
print('Tail regression source: audio extends 250 ms beyond real video.')
PYTAIL
"$task_dir/native" export "$task_dir/media/request.json"
# Website export must render once and finish both AV1 and VP9 files.
python3 - "$task_dir/media" <<'PYWEB'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); request=json.loads(p.joinpath('request.json').read_text())
request.update(encoder='web',output=str(p/'website'))
p.joinpath('web-request.json').write_text(json.dumps(request))
PYWEB
"$task_dir/native" export "$task_dir/media/web-request.json"
python3 - "$task_dir/media/website" <<'PYWEBCHECK'
import json,pathlib,subprocess,sys,platform
p=pathlib.Path(sys.argv[1]); target='aarch64' if platform.machine()=='arm64' else 'x86_64'
probe=f'src-tauri/binaries/ffprobe-{target}-apple-darwin'
for filename,codec in [('video-av1.webm','av1'),('video-vp9.webm','vp9')]:
 info=json.loads(subprocess.check_output([probe,'-v','error','-show_streams','-show_format','-of','json',str(p/filename)]))
 video=next(s for s in info['streams'] if s['codec_type']=='video')
 assert video['codec_name']==codec and (video['width'],video['height'])==(2560,1600),video
 assert any(s['codec_type']=='audio' for s in info['streams']),info
 assert abs(float(info['format']['duration'])-2)<0.04,info
html=p.joinpath('embed.html').read_text()
assert 'av01.0.' in html and 'vp9' in html and html.index('video-av1.webm')<html.index('video-vp9.webm')
print('Composited website export passed: paired codecs, dimensions, audio, duration and codec-aware embed.')
PYWEBCHECK
python3 - "$task_dir/media" <<'PYH264'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); request=json.loads(p.joinpath('request.json').read_text())
request.update(encoder='h264',output=str(p/'h264-rendered.mp4'))
p.joinpath('h264-request.json').write_text(json.dumps(request))
PYH264
"$task_dir/native" export "$task_dir/media/h264-request.json"
"$task_dir/native" inspect "$task_dir/media/h264-rendered.mp4" > "$task_dir/h264-inspection.json"
python3 - "$task_dir/h264-inspection.json" <<'PYH264CHECK'
import json,sys
v=json.load(open(sys.argv[1]))
assert v['codec']==int.from_bytes(b'avc1','big') and v['hasAudio'],v
assert (v['width'],v['height'])==(2560,1600) and 1.9<v['durationUs']/1e6<2.1,v
print('Composited H.264 MP4 export passed: VideoToolbox codec, dimensions, audio and video ending.')
PYH264CHECK
"$task_dir/native" inspect "$task_dir/media/rendered.mp4" > "$task_dir/inspection.json"
python3 - "$task_dir/inspection.json" <<'PY'
import json,sys
import pathlib
for path in [pathlib.Path(sys.argv[1])]:
 v=json.load(open(path))
 assert (v['width'],v['height'])==(2560,1600),v
 assert 1.9<v['durationUs']/1e6<2.1,v
 assert v['hasAudio'] and abs(v['fps']-30)<0.01,v
 assert v['codec']==int.from_bytes(b'hvc1','big'),v
 assert v['bitDepth']==10 and v['hevcProfile']==2,v
 print(f'{path.name}: export codec, dimensions, duration, frame rate and audio passed.')

print('Native export passed: 2560x1600 16:10, HEVC Main 10, source fps, audio and video cut together.')
PY
python3 - "$task_dir/media/rendered.mp4" <<'PYMP4'
import pathlib,struct,sys
for path in [pathlib.Path(sys.argv[1])]:
 atoms=[]
 with open(path,'rb') as f:
  while header:=f.read(8):
   size,kind=struct.unpack('>I4s',header); header_size=8
   if size==1: size=struct.unpack('>Q',f.read(8))[0];header_size=16
   atoms.append(kind)
   if size==0: break
   f.seek(size-header_size,1)
 assert atoms.index(b'moov') < atoms.index(b'mdat'), (path,atoms)
print('Web optimization passed: moov precedes mdat for progressive playback.')
PYMP4
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/VideoTiming.swift scripts/audio-ending-tests.swift -o "$task_dir/audio-ending"
"$task_dir/audio-ending" "$task_dir/media/rendered.mp4"
# A sparse legacy cursor must hold through an idle gap, then arrive on time.
python3 - "$task_dir/media" <<'PYTIMING'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
p.joinpath('cursor/events.jsonl').write_text(''.join(json.dumps({'tUs':t,'type':'move','x':x,'y':y,'visible':x<640,'cursorID':shape,'click':t==500000,'clickUs':t})+'\n' for t,x,y,shape in [(0,80,60,'arrow'),(500000,80,60,'arrow'),(1000000,500,60,'text'),(1500000,500,60,'hand'),(1800000,638,200,'hand'),(1900000,650,200,'hand')]))
m=json.loads(p.joinpath('manifest.json').read_text())
m['appearance']['clickAnimation']=True
p.joinpath('manifest.json').write_text(json.dumps(m))
request=json.loads(p.joinpath('request.json').read_text())
request['output']=str(p/'timing-rendered.mp4')
p.joinpath('timing-request.json').write_text(json.dumps(request))
PYTIMING
"$task_dir/native" export "$task_dir/media/timing-request.json"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CursorAppearance.swift src-tauri/native/CursorTimeline.swift scripts/verify-cursor-render.swift -o "$task_dir/verify-cursor-render"
"$task_dir/verify-cursor-render" "$task_dir/media/timing-rendered.mp4" "$task_dir/media/cursor/assets.json"
# Fractional destination edges must never reveal the compositor's black canvas.
python3 - "$task_dir/media" <<'PYEDGE'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
# Keep the seam scan independent of the cursor deliberately crossing that rim.
p.joinpath('cursor/events.jsonl').write_text('')
m=json.loads(p.joinpath('manifest.json').read_text())
m['appearance']['background']={'type':'gradient','preset':'dawn'}
p.joinpath('manifest.json').write_text(json.dumps(m))
r=json.loads(p.joinpath('request.json').read_text())
r['output']=str(p/'edge-rendered.mp4')
p.joinpath('edge-request.json').write_text(json.dumps(r))
PYEDGE
"$task_dir/native" export "$task_dir/media/edge-request.json"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CaptureGeometry.swift scripts/verify-edge-render.swift -o "$task_dir/verify-edge-render"
"$task_dir/verify-edge-render" "$task_dir/media/edge-rendered.mp4"
# Encoded black shutdown samples have storage bytes and decode successfully.
# They must be removed before the background can disguise the missing picture.
"$task_dir/fixture" "$task_dir/blank-tail" --blank-tail
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/VideoTiming.swift scripts/video-ending-tests.swift -o "$task_dir/video-ending"
"$task_dir/video-ending" "$task_dir/blank-tail/source.mov"
python3 scripts/prepare-smoke.py "$task_dir/blank-tail"
python3 - "$task_dir/blank-tail/manifest.json" <<'PYBLANK'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); m=json.loads(p.read_text())
m['appearance']['background']={'type':'gradient','preset':'dawn'}
p.write_text(json.dumps(m))
PYBLANK
"$task_dir/native" export "$task_dir/blank-tail/request.json"
"$task_dir/verify-edge-render" "$task_dir/blank-tail/rendered.mp4"
# Cancellation must never report a completed render.
rm "$task_dir/media/rendered.mp4"
touch "$task_dir/media/cancel-export"
if "$task_dir/native" export "$task_dir/media/request.json"; then
  echo "Cancellation unexpectedly completed" >&2
  exit 1
fi
echo "Native cancellation passed."
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/ExportEncoder.swift src-tauri/native/FFmpegEncoder.swift scripts/encoder-cancel-tests.swift -o "$task_dir/encoder-cancel"
"$task_dir/encoder-cancel" "$task_dir/media/media/source.mov"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/ExportEncoder.swift src-tauri/native/FFmpegEncoder.swift scripts/ffmpeg-encoder-tests.swift -o "$task_dir/ffmpeg-tests"
"$task_dir/ffmpeg-tests" "$task_dir/media/media/source.mov"
python3 - "$task_dir/media" <<'PYCLEAN'
import pathlib,sys
assert not list(pathlib.Path(sys.argv[1]).glob('render-*.mov')), 'Temporary master leaked'
print('Temporary master cleanup passed.')
PYCLEAN

