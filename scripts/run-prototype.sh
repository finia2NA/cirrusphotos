#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
prototype_bin_dir="$(swift build --show-bin-path)"
prototype_app="$PWD/.build/Cirrus Timeline.app"
mkdir -p "$prototype_app/Contents/MacOS" "$prototype_app/Contents/Resources"
cp "$prototype_bin_dir/SynoTimeline" "$prototype_app/Contents/MacOS/"
cp scripts/Prototype-Info.plist "$prototype_app/Contents/Info.plist"
cp -R "$prototype_bin_dir/SynoTimeline_TimelinePrototype.bundle" "$prototype_app/Contents/Resources/"
open "$prototype_app"
