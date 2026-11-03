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
# The NAS host comes from NAS_URL in .env (read only for that key; nothing is printed).
nas_url="$(sed -n 's/^NAS_URL=//p' .env | head -1 | tr -d "\"'")"
nas_host="${nas_url#*://}"; nas_host="${nas_host%%[:/]*}"
if [[ -z "$nas_host" ]]; then
    echo "NAS_URL is missing or invalid in .env (see .env.example)." >&2
    exit 1
fi
sed "s/__NAS_HOST__/$nas_host/" scripts/App-Info.plist > "$app_bundle/Contents/Info.plist"
codesign --force --deep --sign - "$app_bundle"

if [[ ${1:-} != "--build-only" ]]; then
    open "$app_bundle"
fi
