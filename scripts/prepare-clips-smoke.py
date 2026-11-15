"""Extend the native fixture into a two-clip project without flattening sources."""
import copy
import json
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
clips = []
for id in ['0001', '0002']:
    folder = root / 'clips' / id
    shutil.copytree(root / 'media', folder / 'media')
    shutil.copytree(root / 'cursor', folder / 'cursor')
    media = copy.deepcopy(manifest['media'])
    media['path'] = f'clips/{id}/media/source.mov'
    cursor = dict(manifest['cursor'], path=f'clips/{id}/cursor/events.jsonl')
    clips.append(dict(id=id, media=media, cursor=cursor))
manifest.update(formatVersion=2, clips=clips, sequence=[{'clipId': c['id']} for c in clips])
manifest['media'] = dict(clips[0]['media'], durationUs=4_000_000)
manifest['cursor'] = clips[0]['cursor']
(root / 'manifest.json').write_text(json.dumps(manifest))
request = dict(json.loads((root / 'request.json').read_text()), output=str(root / 'clips.mp4'))
(root / 'clips-request.json').write_text(json.dumps(request))
