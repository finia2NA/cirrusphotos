#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--build-only") ]]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi

swift build --product SynoTimeline
bin_dir="$(swift build --show-bin-path)"
app_bundle="$PWD/.build/Cirrus Photos.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$bin_dir/SynoTimeline" "$app_bundle/Contents/MacOS/"
cp scripts/App-Info.plist "$app_bundle/Contents/Info.plist"
codesign --force --deep --sign - "$app_bundle"

if [[ ${1:-} != "--build-only" ]]; then
    open "$app_bundle"
fi
