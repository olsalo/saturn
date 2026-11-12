#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/saturn-web.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library scripts/generate-fixture.swift -o "$task_dir/fixture"
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library src-tauri/native/ExportEncoder.swift src-tauri/native/FFmpegEncoder.swift scripts/web-export-tests.swift -o "$task_dir/web-tests"
"$task_dir/fixture" "$task_dir/source"
"$task_dir/web-tests" "$task_dir/source/source.mov" "$task_dir/output"
