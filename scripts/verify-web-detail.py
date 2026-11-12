"""Decode via FFmpeg so AV1 checks do not depend on macOS decoder support.

Usage: python3 scripts/verify-web-detail.py master.mov export.mp4 [--controls]
The --controls check targets the retained real UI fixture in WEB_EXPORT_VALIDATION.md.
"""
import json
import math
import pathlib
import platform
import subprocess
import sys

target = "aarch64" if platform.machine() == "arm64" else "x86_64"
ffmpeg = f"src-tauri/binaries/ffmpeg-{target}-apple-darwin"
ffprobe = f"src-tauri/binaries/ffprobe-{target}-apple-darwin"
reference, encoded = sys.argv[1:3]
info = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_streams", "-of", "json", encoded]))
video = next(s for s in info["streams"] if s["codec_type"] == "video")
width, height = video["width"], video["height"]
duration = float(video.get("duration") or json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_format", "-of", "json", encoded]))["format"]["duration"])


def frame(path, seconds):
    data = subprocess.check_output([
        ffmpeg, "-v", "error", "-nostdin", "-ss", str(seconds), "-i", path,
        "-map", "0:v:0", "-frames:v", "1", "-vf", f"scale={width}:{height},format=rgb24",
        "-c:v", "rawvideo", "-f", "rawvideo", "pipe:1",
    ])
    assert len(data) == width * height * 3, "Decoded frame is incomplete"
    return data


def psnr(error, count):
    return 99 if error == 0 else 10 * math.log10(255 * 255 * count / error)


first = None
for seconds in [0, math.floor(duration * 15) / 30, max(0, (round(duration * 30) - 1) / 30)]:
    a, b = frame(reference, seconds), frame(encoded, seconds)
    if first is None:
        first = a, b
    squared = edge_squared = count = edge_count = black = 0
    for y in range(16, height - 16, 4):
        for x in range(16, width - 16, 4):
            offset = (y * width + x) * 3
            edge = any(abs(a[offset + c] - a[offset + 3 + c]) > 12 or
                       abs(a[offset + c] - a[offset + width * 3 + c]) > 12 for c in range(3))
            for c in range(3):
                error = (a[offset + c] - b[offset + c]) ** 2
                squared += error
                count += 1
                if edge:
                    edge_squared += error
                    edge_count += 1
            if min(a[offset:offset + 3]) > 200 and max(b[offset:offset + 3]) < 40:
                black += 1
    overall, edges = psnr(squared, count), psnr(edge_squared, edge_count)
    assert overall >= 38 and edges >= 30 and black == 0, (seconds, overall, edges, black)
    print(f"{seconds:.3f}s: RGB PSNR {overall:.2f} dB, edges {edges:.2f} dB, unexpected black patches {black}")

if "--controls" in sys.argv:
    scale = width / 3456

    def contrast(data, cx, degrees):
        angle = degrees * math.pi / 180
        darkest = 1.0
        for step in range(18, 35):
            radius = step / 2 * scale
            x = round(cx * scale + math.cos(angle) * radius)
            y = round(203 * scale + math.sin(angle) * radius)
            offset = (y * width + x) * 3
            r, g, b = data[offset:offset + 3]
            darkest = min(darkest, (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
        return 1 - darkest

    missing = total = 0
    for cx in [308, 352, 396]:
        for degrees in range(0, 360, 5):
            expected = contrast(first[0], cx, degrees)
            if expected > 0.06:
                total += 1
                missing += contrast(first[1], cx, degrees) < expected * 0.5
    assert total >= 120 and missing <= total // 100, (missing, total)
    print(f"Window control outlines: {total - missing}/{total} samples retained")
print(f"{pathlib.Path(encoded).name}: software-decoded web detail checks passed")
