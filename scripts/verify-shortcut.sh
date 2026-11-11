#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/saturn-shortcut.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT
swiftc -module-cache-path "$task_dir/cache" -swift-version 5 -parse-as-library -D SATURN_BRIDGE \
  src-tauri/native/RecordingShortcut.swift scripts/recording-shortcut-tests.swift -o "$task_dir/shortcut"
"$task_dir/shortcut"
