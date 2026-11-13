#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/betterrecorder-meeting-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 "$project_dir/Sources/BetterRecorder/CodexChatBridge.swift" "$project_dir/Support/tests/BridgeChecks.swift" -o "$check_dir/bridge-check"
"$check_dir/bridge-check"
swiftc -swift-version 6 "$project_dir/Sources/BetterRecorder/MeetingTranscriptBatcher.swift" "$project_dir/Support/tests/MeetingBatchChecks.swift" -o "$check_dir/batch-check"
"$check_dir/batch-check"
