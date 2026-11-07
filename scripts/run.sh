#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "Usage: $0 [--release] [--build-only] [--distribution]" >&2; exit 2; }
build_only=false
configuration=debug
distribution=false
for argument in "$@"; do
    case "$argument" in
        --build-only) build_only=true ;;
        --release) configuration=release ;;
        # The public build: optimized, never opened, no .env lookup, cache in Application
        # Support, no ATS exception. It has its own build directory and bundle path.
        --distribution) distribution=true; configuration=release; build_only=true ;;
        *) usage ;;
    esac
done

build=(swift build -c "$configuration")
build_dir="$PWD/.build"
if [[ $distribution == true ]]; then
    build_dir="$PWD/.build/distribution"
    build+=(--scratch-path "$build_dir" -Xswiftc -DCIRRUS_DISTRIBUTION)
fi
"${build[@]}" --product CirrusPhotos
bin_dir="$("${build[@]}" --show-bin-path)"
app_bundle="$build_dir/Cirrus Photos.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$bin_dir/CirrusPhotos" "$app_bundle/Contents/MacOS/"
xcrun actool --compile "$app_bundle/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 \
    --app-icon AppIcon --output-partial-info-plist "$build_dir/AppIcon-Info.plist" \
    Resources/AppIcon.icon >/dev/null
info_plist="$app_bundle/Contents/Info.plist"
if [[ $distribution == true ]]; then
    # Distribution builds sign in over HTTPS from their own window and need no ATS exception.
    cp scripts/App-Info.plist "$info_plist"
    plutil -remove NSAppTransportSecurity "$info_plist"
else
    # The .env NAS host gets an ATS exception (read only for that key; nothing is printed).
    # Without .env the app signs in from its own window over HTTPS and needs no exception.
    nas_host=localhost
    if [[ -f .env ]]; then
        nas_url="$(sed -n 's/^NAS_URL=//p' .env | head -1 | tr -d "\"'")"
        nas_host="${nas_url#*://}"; nas_host="${nas_host%%[:/]*}"
        if [[ -z "$nas_host" ]]; then
            echo "NAS_URL is missing or invalid in .env (see .env.example)." >&2
            exit 1
        fi
    fi
    sed "s/__NAS_HOST__/$nas_host/" scripts/App-Info.plist > "$info_plist"
fi
plutil -lint -s "$info_plist"
# A stable signing identity keeps the app's Keychain access ("Always Allow") across
# rebuilds; an ad-hoc signature changes with every build, so macOS asks again.
# CODESIGN_IDENTITY overrides; otherwise the first Apple Development identity is used.
# No entitlements: only scripts/profile.sh adds get-task-allow, and only to the development bundle.
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
codesign --force --deep --sign "${identity:--}" "$app_bundle"
# Refresh Launch Services' cached icon when the existing bundle is rebuilt.
touch "$app_bundle"

if [[ $distribution == true ]]; then
    echo "Built distribution bundle: $app_bundle"
else
    echo "Built $configuration bundle: $app_bundle"
fi
if [[ $build_only == false ]]; then
    open "$app_bundle"
fi
