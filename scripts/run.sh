#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "Usage: $0 [--release] [--build-only]" >&2; exit 2; }
build_only=false
configuration=debug
for argument in "$@"; do
    case "$argument" in
        --build-only) build_only=true ;;
        --release) configuration=release ;;
        *) usage ;;
    esac
done

swift build -c "$configuration" --product SynoTimeline
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_bundle="$PWD/.build/Cirrus Photos.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$bin_dir/SynoTimeline" "$app_bundle/Contents/MacOS/"
xcrun actool --compile "$app_bundle/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 \
    --app-icon AppIcon --output-partial-info-plist "$PWD/.build/AppIcon-Info.plist" \
    Resources/AppIcon.icon >/dev/null
# The NAS host comes from NAS_URL in .env (read only for that key; nothing is printed).
nas_url="$(sed -n 's/^NAS_URL=//p' .env | head -1 | tr -d "\"'")"
nas_host="${nas_url#*://}"; nas_host="${nas_host%%[:/]*}"
if [[ -z "$nas_host" ]]; then
    echo "NAS_URL is missing or invalid in .env (see .env.example)." >&2
    exit 1
fi
sed "s/__NAS_HOST__/$nas_host/" scripts/App-Info.plist > "$app_bundle/Contents/Info.plist"
codesign --force --deep --sign - "$app_bundle"
# Refresh Launch Services' cached icon when the existing bundle is rebuilt.
touch "$app_bundle"

echo "Built $configuration bundle: $app_bundle"
if [[ $build_only == false ]]; then
    open "$app_bundle"
fi
