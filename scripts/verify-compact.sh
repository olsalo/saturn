#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/saturn-compact.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -O -parse-as-library scripts/generate-fixture.swift -o "$task_dir/fixture"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -O -parse-as-library src-tauri/native/ExportEncoder.swift src-tauri/native/FFmpegEncoder.swift src-tauri/native/VideoTiming.swift scripts/compact-export-tests.swift -o "$task_dir/compact"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -O -parse-as-library scripts/verify-hevc-patches.swift -o "$task_dir/patches"
if [ "$#" -gt 0 ]; then
  source_video="$1"
else
  "$task_dir/fixture" "$task_dir/source"
  source_video="$task_dir/source/source.mov"
fi
"$task_dir/compact" "$source_video" "$task_dir/export"
"$task_dir/patches" "$task_dir/export/reference.mov" "$task_dir/export/compact.mp4"
