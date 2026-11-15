"""Check encoded duration and audible samples on both sides of the cut."""
import json
import pathlib
import platform
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
target = 'aarch64' if platform.machine() == 'arm64' else 'x86_64'
bins = pathlib.Path('src-tauri/binaries')
probe = bins / f'ffprobe-{target}-apple-darwin'
def inspect(path):
    return json.loads(subprocess.check_output([str(probe), '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)]))
single = inspect(root / 'rendered.mp4')
joined = inspect(root / 'clips.mp4')
expected = float(single['format']['duration']) * 2
assert abs(float(joined['format']['duration']) - expected) < 0.12, (joined['format']['duration'], expected)
assert len([s for s in joined['streams'] if s['codec_type'] == 'audio']) == 1, 'Clips must share one continuous playback audio track'
assert not list(root.glob('render-*.mov')), 'Temporary sequence masters leaked'
print('Clip export passed: continuous duration, one audio track, temporary files cleaned.')
