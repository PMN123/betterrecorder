#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle_dir="$project_dir/dist/BetterRecorder.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$binary_dir/BetterRecorder" "$bundle_dir/Contents/MacOS/BetterRecorder"
cp "$project_dir/Support/Info.plist" "$bundle_dir/Contents/Info.plist"
if [[ -f "$project_dir/Support/AppIcon.icns" ]]; then
    cp "$project_dir/Support/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --identifier io.github.PMN123.BetterRecorder "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"
print -r -- "Built $bundle_dir"

if [[ "${1:-}" == "--install" ]]; then
    install_dir="$HOME/Applications/BetterRecorder.app"
    mkdir -p "$HOME/Applications"
    if pgrep -x BetterRecorder >/dev/null; then
        print -u2 -- "Quit BetterRecorder before replacing the installed app."
        exit 1
    fi
    ditto "$bundle_dir" "$install_dir"
    print -r -- "Installed $install_dir"
fi
