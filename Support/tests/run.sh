#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/betterrecorder-media-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
export BETTERRECORDER_CHECK_DIR="$check_dir"

cp "$project_dir/Sources/BetterRecorder/CaptureWriter.swift" "$check_dir/CaptureWriter.swift"
cat >> "$check_dir/CaptureWriter.swift" <<'SWIFT'

// Only this temporary test copy exposes sample injection.
extension CaptureWriter {
    func testVideo(_ sample: CMSampleBuffer) { queue.sync { acceptVideo(sample) } }
    func testAudio(_ sample: CMSampleBuffer, mic: Bool) { queue.sync { acceptAudio(sample, microphone: mic) } }
}
SWIFT
cp "$project_dir/Support/tests/main.swift" "$check_dir/main.swift"
swiftc -swift-version 5 "$check_dir/CaptureWriter.swift" "$check_dir/main.swift" -o "$check_dir/media-check"
"$check_dir/media-check"
swiftc -swift-version 5 "$project_dir/Sources/BetterRecorder/CaptureWriter.swift" "$project_dir/Support/tests/EdgeChecks.swift" -o "$check_dir/edge-check"
"$check_dir/edge-check"
