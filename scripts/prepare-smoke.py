"""Prepare a synthetic, permission-free compositor fixture."""
import datetime
import json
import pathlib
import shutil
import sys
import uuid
p = pathlib.Path(sys.argv[1])
for name in ['media', 'cursor', 'assets', 'preview']:
    (p / name).mkdir(exist_ok=True)
shutil.copy(p / 'source.mov', p / 'media/source.mov')
m = {
    'formatVersion': 1, 'projectId': str(uuid.uuid4()),
    'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'media': {'path': 'media/source.mov', 'durationUs': 2000000, 'width': 640, 'height': 400,
              'frameRate': {'numerator': 30, 'denominator': 1}, 'hasSystemAudio': True, 'hasMicrophoneAudio': False},
    'cursor': {'path': 'cursor/events.jsonl', 'timeUnit': 'microseconds', 'coordinateSpace': 'capturedVideoPixels'},
    'appearance': {'background': {'type': 'embeddedImage', 'path': 'assets/background.jpg', 'preset': 'tahoe-light.jpg'}, 'paddingPx': 64, 'paddingPercent': 38,
                   'cornerRadiusPx': 16, 'shadow': True, 'cursorSmoothing': True, 'clickAnimation': False},
    'export': {'container': 'mp4', 'codec': 'h264', 'width': 2560, 'height': 1600, 'frameRate': 30},
}
shutil.copy(pathlib.Path(__file__).resolve().parent.parent / 'public/wallpapers/apple/tahoe-light.jpg', p / 'assets/background.jpg')
(p / 'manifest.json').write_text(json.dumps(m))
(p / 'cursor/events.jsonl').write_text(''.join(json.dumps({'tUs': i*33333, 'type': 'move',
    'x': 30+i*8, 'y': 150, 'visible': True})+'\n' for i in range(60)))
(p / 'request.json').write_text(json.dumps({'workspace': str(p), 'output': str(p / 'rendered.mp4')}))
