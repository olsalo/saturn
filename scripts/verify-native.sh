#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -m)" in arm64) target=arm64;; x86_64) target=x86_64;; *) exit 1;; esac
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/saturn-smoke.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" scripts/generate-fixture.swift -o "$task_dir/fixture"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/RecorderNative.swift src-tauri/native/VideoTiming.swift src-tauri/native/HandBrakeEncoder.swift src-tauri/native/FFmpegEncoder.swift src-tauri/native/CursorAppearance.swift src-tauri/native/CursorTimeline.swift src-tauri/native/CaptureGeometry.swift src-tauri/native/CapturePermission.swift -o "$task_dir/native"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CaptureGeometry.swift scripts/capture-geometry-tests.swift -o "$task_dir/geometry"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CapturePermission.swift scripts/capture-permission-tests.swift -o "$task_dir/permissions"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/CursorTimeline.swift scripts/cursor-timing-tests.swift -o "$task_dir/cursor-timing"
"$task_dir/cursor-timing"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -D SATURN_BRIDGE -target "$target-apple-macosx15.0" src-tauri/native/RecorderNative.swift src-tauri/native/VideoTiming.swift src-tauri/native/HandBrakeEncoder.swift src-tauri/native/FFmpegEncoder.swift src-tauri/native/CursorAppearance.swift src-tauri/native/CursorTimeline.swift src-tauri/native/CaptureGeometry.swift src-tauri/native/CapturePermission.swift scripts/cursor-startup-tests.swift -o "$task_dir/cursor-startup"
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
# Exercise the optional encoder through the real compositor when available.
python3 - "$task_dir/media" <<'PYVT'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
r=json.loads(p.joinpath('request.json').read_text())
r.update(encoder='videotoolbox', output=str(p/'toolbox-rendered.mp4'))
p.joinpath('toolbox-request.json').write_text(json.dumps(r))
PYVT
case "$target" in arm64) encoder_target=aarch64;; *) encoder_target=x86_64;; esac
encoder_help=$("src-tauri/binaries/HandBrakeCLI-$encoder_target-apple-darwin" --help 2>/dev/null)
if [[ "$encoder_help" == *vt_h265_10bit* ]]; then
  "$task_dir/native" export "$task_dir/media/toolbox-request.json"
  "$task_dir/native" inspect "$task_dir/media/toolbox-rendered.mp4" > "$task_dir/toolbox-inspection.json"
else
  if "$task_dir/native" export "$task_dir/media/toolbox-request.json" > "$task_dir/toolbox-error.json"; then
    echo "Unavailable VideoToolbox unexpectedly succeeded" >&2
    exit 1
  fi
  python3 - "$task_dir/toolbox-error.json" <<'PYVTERROR'
import json,pathlib,sys
assert 'VideoToolbox HEVC 10-bit encoding is unavailable' in json.load(open(sys.argv[1]))['message']
assert not (pathlib.Path(sys.argv[1]).parent/'media/toolbox-rendered.mp4').exists()
assert not list((pathlib.Path(sys.argv[1]).parent/'media').glob('render-*.mov'))
print('VideoToolbox unavailable: explicit rejection passed; hardware export checks skipped.')
PYVTERROR
fi
"$task_dir/native" inspect "$task_dir/media/rendered.mp4" > "$task_dir/inspection.json"
python3 - "$task_dir/inspection.json" <<'PY'
import json,sys
import pathlib
for path in [pathlib.Path(sys.argv[1]), *pathlib.Path(sys.argv[1]).parent.glob('toolbox-inspection.json')]:
 v=json.load(open(path))
 assert (v['width'],v['height'])==(2560,1600),v
 assert 1.9<v['durationUs']/1e6<2.1,v
 assert v['hasAudio'] and abs(v['fps']-30)<0.01,v
 assert v['codec']==int.from_bytes(b'hvc1','big'),v
 assert v['bitDepth']==10 and v['hevcProfile']==2,v
 print(f'{path.name}: export codec, dimensions, duration, frame rate and audio passed.')

print('Native export passed: 2560x1600 16:10, HEVC Main 10, source fps, 2 seconds, audio retained.')
PY
python3 - "$task_dir/media/rendered.mp4" <<'PYMP4'
import pathlib,struct,sys
for path in [pathlib.Path(sys.argv[1]), *pathlib.Path(sys.argv[1]).parent.glob('toolbox-rendered.mp4')]:
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
if [[ "$encoder_help" == *vt_h265_10bit* ]]; then
  rm "$task_dir/media/audio-tail-regression.mp4"
  "$task_dir/audio-ending" "$task_dir/media/toolbox-rendered.mp4"
fi
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
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/HandBrakeEncoder.swift src-tauri/native/FFmpegEncoder.swift scripts/handbrake-cancel-tests.swift -o "$task_dir/encoder-cancel"
"$task_dir/encoder-cancel" "$task_dir/media/media/source.mov"
"$task_dir/encoder-cancel" "$task_dir/media/media/source.mov" --ffmpeg
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -target "$target-apple-macosx15.0" src-tauri/native/HandBrakeEncoder.swift src-tauri/native/FFmpegEncoder.swift scripts/ffmpeg-encoder-tests.swift -o "$task_dir/ffmpeg-tests"
"$task_dir/ffmpeg-tests" "$task_dir/media/media/source.mov"
if [[ "$encoder_help" == *vt_h265_10bit* ]]; then
  "$task_dir/encoder-cancel" "$task_dir/media/media/source.mov" --videotoolbox
fi
python3 - "$task_dir/media" <<'PYCLEAN'
import pathlib,sys
assert not list(pathlib.Path(sys.argv[1]).glob('render-*.mov')), 'Temporary master leaked'
print('Temporary master cleanup passed.')
PYCLEAN

