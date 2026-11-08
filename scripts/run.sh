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
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
cp "$bin_dir/CirrusPhotos" "$app_bundle/Contents/MacOS/"
# The executable links Sparkle in every build mode and finds it through its
# @executable_path/../Frameworks rpath (Package.swift); only distribution builds start the updater.
rm -rf "$app_bundle/Contents/Frameworks/Sparkle.framework"
ditto "$bin_dir/Sparkle.framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
# SwiftPM also adds absolute build-directory rpaths, which would load Sparkle from outside the bundle.
otool -l "$app_bundle/Contents/MacOS/CirrusPhotos" | sed -n 's|^ *path \(/.*\) (offset [0-9]*)$|\1|p' |
    while read -r rpath; do
        install_name_tool -delete_rpath "$rpath" "$app_bundle/Contents/MacOS/CirrusPhotos"
    done
xcrun actool --compile "$app_bundle/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 \
    --app-icon AppIcon --output-partial-info-plist "$build_dir/AppIcon-Info.plist" \
    Resources/AppIcon.icon >/dev/null
info_plist="$app_bundle/Contents/Info.plist"
# Development builds have their own bundle ID (AppIdentity), so their preferences, Keychain
# items and logs stay apart from an installed distribution build.
bundle_id=io.github.finia2na.cirrusphotos
[[ $distribution == true ]] || bundle_id="$bundle_id.dev"
if [[ $distribution == true ]]; then
    # Distribution builds sign in over HTTPS from their own window and need no ATS exception.
    sed "s/__BUNDLE_ID__/$bundle_id/g" scripts/App-Info.plist > "$info_plist"
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
    sed -e "s/__NAS_HOST__/$nas_host/" -e "s/__BUNDLE_ID__/$bundle_id/g" scripts/App-Info.plist > "$info_plist"
fi
# The version comes only from scripts/version.env (the template has no version keys).
source scripts/version.env
plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$info_plist"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$info_plist"
if [[ $distribution == true ]]; then
    # Sparkle's feed and the public half of the update signing key. SITE_URL defaults to the
    # Makefile's value. Sparkle asks on the second launch whether to check automatically and
    # never downloads updates without asking (no SUEnableAutomaticChecks/SUAutomaticallyUpdate).
    source scripts/sparkle.env
    site_url="${SITE_URL:-$(make --no-print-directory -s print-site-url)}"
    plutil -insert SUFeedURL -string "${site_url%/}/appcast.xml" "$info_plist"
    plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$info_plist"
fi
cp Resources/ThirdPartyNotices.json "$app_bundle/Contents/Resources/"
plutil -lint -s "$info_plist"
# The stable "Cirrus Photos" identity keeps Keychain access ("Always Allow") across rebuilds and
# lets Sparkle accept updates. Development builds fall back to an ad-hoc signature, which changes
# with every build, so macOS asks for Keychain access again; distribution builds require it.
# No entitlements: only scripts/profile.sh adds get-task-allow, and only to the development bundle.
source scripts/signing.sh
identity="$(signing_identity)"
if [[ -z $identity ]]; then
    if [[ $distribution == true ]]; then
        echo "No trusted \"$SIGNING_NAME\" signing certificate; run scripts/make-signing-cert.sh." >&2
        exit 1
    fi
    echo "Warning: no \"$SIGNING_NAME\" signing certificate (scripts/make-signing-cert.sh); signing ad hoc." >&2
fi
# Nested code is signed inside-out before the app, as Sparkle documents for apps signed
# outside Xcode (no --deep): XPC services, Autoupdate, Updater.app, then the framework.
sign=(codesign --force --sign "${identity:--}")
sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
"${sign[@]}" -o runtime "$sparkle/XPCServices/Installer.xpc"
"${sign[@]}" -o runtime --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
"${sign[@]}" -o runtime "$sparkle/Autoupdate"
"${sign[@]}" -o runtime "$sparkle/Updater.app"
"${sign[@]}" -o runtime "$app_bundle/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" "$app_bundle"
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
