#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/saturn-color-check.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -D SATURN_BRIDGE \
  -target "$(uname -m)-apple-macosx15.0" \
  src-tauri/native/RecorderNative.swift src-tauri/native/VideoTiming.swift \
  src-tauri/native/HandBrakeEncoder.swift src-tauri/native/FFmpegEncoder.swift src-tauri/native/CursorAppearance.swift \
  src-tauri/native/CursorTimeline.swift src-tauri/native/CaptureGeometry.swift \
  src-tauri/native/CapturePermission.swift scripts/capture-color-tests.swift -o "$task_dir/colors"
"$task_dir/colors"
