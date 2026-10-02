#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
prototype_bin_dir="$(swift build --show-bin-path)"
prototype_app="$PWD/.build/Cirrus Photos.app"
mkdir -p "$prototype_app/Contents/MacOS" "$prototype_app/Contents/Resources"
cp "$prototype_bin_dir/SynoTimeline" "$prototype_app/Contents/MacOS/"
cp scripts/Prototype-Info.plist "$prototype_app/Contents/Info.plist"
codesign --force --deep --sign - "$prototype_app"
open "$prototype_app"
