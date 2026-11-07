#!/bin/bash
# Release steps behind `make dmg`, `make publish` and `make deploy-site`; the Makefile passes
# DEPLOY_HOST, DEPLOY_PATH, SITE_URL, GITHUB_REPO, ALLOW_DIRTY and DRY_RUN.
# Publishing works from whichever branch is checked out; there is no release branch yet.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEPLOY_HOST:?}" "${DEPLOY_PATH:?}" "${SITE_URL:?}" "${GITHUB_REPO:?}"
ALLOW_DIRTY="${ALLOW_DIRTY:-}"
DRY_RUN="${DRY_RUN:-}"
SITE_URL="${SITE_URL%/}"

source scripts/version.env
source scripts/sparkle.env
source scripts/signing.sh
version="$MARKETING_VERSION"
tag="v$version"
# Not .build/release, which is SwiftPM's release products link.
release_dir="$PWD/.build/releases"
mkdir -p "$release_dir"
dmg_name="Cirrus-Photos-$version.dmg"
dmg="$release_dir/$dmg_name"
notes_file="$release_dir/notes-$version.md"
item_file="$release_dir/appcast-item-$version.xml"
appcast="website/appcast.xml"
app="$PWD/.build/distribution/Cirrus Photos.app"
# The private key lives in the main checkout's gitignored secrets/, also from a worktree.
main_checkout="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
key_file="${SPARKLE_KEY_FILE:-$main_checkout/secrets/sparkle_ed25519_private.key}"

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }
# Runs a publishing command, or only prints it with DRY_RUN=1.
run() {
    if [[ -n $DRY_RUN ]]; then
        printf '[dry run]'; printf ' %q' "$@"; echo
    else
        "$@"
    fi
}

require_clean_tree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        [[ -n $ALLOW_DIRTY ]] || fail "the working tree is not clean (ALLOW_DIRTY=1 overrides for testing)"
        echo "warning: building from an unclean tree (ALLOW_DIRTY=1)" >&2
    fi
}

sparkle_tool() {
    local name="$1" dir
    for dir in .build/distribution/artifacts .build/artifacts; do
        if [[ -x "$dir/sparkle/Sparkle/bin/$name" ]]; then echo "$dir/sparkle/Sparkle/bin/$name"; return; fi
    done
    fail "Sparkle's $name was not found; run swift package resolve"
}

highest_published_build() {
    local highest=""
    if [[ -f $appcast ]]; then
        highest="$({ grep -oE '<sparkle:version>[0-9]+</sparkle:version>|sparkle:version="[0-9]+"' "$appcast" || true; } |
            { grep -oE '[0-9]+' || true; } | sort -n | tail -1)"
    fi
    echo "${highest:-0}"
}

# The CHANGELOG.md section "## <version>" without its heading.
write_release_notes() {
    awk -v v="$version" '
        /^## / { inside = ($2 == v); next }
        inside { print }
    ' CHANGELOG.md | sed -e '/./,$!d' | awk '{ lines[NR] = $0 } END {
        last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = 1; i <= last; i++) print lines[i] }' > "$notes_file"
    [[ -s $notes_file ]] || fail "CHANGELOG.md has no section \"## $version\""
}

# Paragraphs and "- " lists of the notes as simple HTML.
notes_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$notes_file" | awk '
        function close_block() {
            if (list) print "</ul>"; if (para) print "</p>"; list = 0; para = 0 }
        /^[[:space:]]*$/ { close_block(); next }
        /^- / { if (para) { print "</p>"; para = 0 }
                if (!list) { print "<ul>"; list = 1 }
                print "<li>" substr($0, 3) "</li>"; next }
        { if (list) { print "</ul>"; list = 0 }
          if (!para) { printf "<p>"; para = 1; print $0 } else print $0 }
        END { close_block() }'
}

cmd_dmg() {
    require_clean_tree
    [[ $BUILD_NUMBER =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER in scripts/version.env must be an integer"
    local published
    published="$(highest_published_build)"
    (( BUILD_NUMBER > published )) ||
        fail "BUILD_NUMBER $BUILD_NUMBER must be greater than the highest published build $published in $appcast"
    [[ -f $key_file ]] || fail "the Sparkle private key $key_file is missing (see README, Releasing)"
    write_release_notes

    step "Running tests"
    swift test

    step "Building the distribution bundle"
    SITE_URL="$SITE_URL" ./scripts/run.sh --distribution

    step "Verifying the bundle"
    codesign --verify --deep --strict "$app"
    local signature_info binary="$app/Contents/MacOS/CirrusPhotos"
    signature_info="$(codesign -dvv "$app" 2>&1)"
    local identity
    identity="$(signing_identity)"
    [[ -n $identity ]] || fail "no trusted \"$SIGNING_NAME\" signing certificate (scripts/make-signing-cert.sh)"
    grep -qx "Authority=$identity" <<<"$signature_info" ||
        fail "the bundle is not signed by \"$identity\"; updates need the same identity as every release"
    local plist="$app/Contents/Info.plist"
    check_key() {
        local actual
        actual="$(plutil -extract "$1" raw -o - "$plist")" || fail "Info.plist has no $1"
        [[ $actual == "$2" ]] || fail "Info.plist $1 is '$actual', expected '$2'"
    }
    check_key CFBundleShortVersionString "$MARKETING_VERSION"
    check_key CFBundleVersion "$BUILD_NUMBER"
    check_key SUFeedURL "$SITE_URL/appcast.xml"
    check_key SUPublicEDKey "$SPARKLE_PUBLIC_ED_KEY"
    [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is not embedded"
    grep -q '@rpath/Sparkle.framework' <<<"$(otool -L "$binary")" ||
        fail "the executable does not link Sparkle through @rpath"
    grep -A2 LC_RPATH <<<"$(otool -l "$binary")" | grep -q '@executable_path/../Frameworks' ||
        fail "the executable has no @executable_path/../Frameworks rpath"

    step "Creating $dmg_name"
    local stage="$release_dir/dmg-stage"
    rm -rf "$stage" "$dmg"
    mkdir -p "$stage"
    ditto "$app" "$stage/Cirrus Photos.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "Cirrus Photos" -srcfolder "$stage" -format UDZO -ov "$dmg"
    rm -rf "$stage"
    codesign --force --sign "$identity" "$dmg"
    codesign --verify --strict "$dmg"

    step "Signing the update"
    local attributes signature
    attributes="$("$(sparkle_tool sign_update)" --ed-key-file "$key_file" "$dmg")"
    signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$attributes")"
    [[ -n $signature ]] || fail "sign_update returned no signature"
    swift scripts/verify_update_signature.swift "$SPARKLE_PUBLIC_ED_KEY" "$signature" "$dmg"

    local pub_date
    pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    {
        echo "    <item>"
        echo "      <title>Version $version</title>"
        echo "      <pubDate>$pub_date</pubDate>"
        echo "      <sparkle:version>$BUILD_NUMBER</sparkle:version>"
        echo "      <sparkle:shortVersionString>$MARKETING_VERSION</sparkle:shortVersionString>"
        echo "      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>"
        echo "      <description><![CDATA["
        notes_html
        echo "]]></description>"
        echo "      <enclosure url=\"https://github.com/$GITHUB_REPO/releases/download/$tag/$dmg_name\""
        echo "                 type=\"application/octet-stream\" $attributes />"
        echo "    </item>"
    } > "$item_file"
    echo "DMG: $dmg"
    echo "Appcast item: $item_file"
    echo "Release notes: $notes_file"
}

# website/appcast.xml with the new item first, written to $1.
appcast_with_item() {
    local out="$1"
    if [[ -f $appcast ]]; then
        cp "$appcast" "$out.base"
    else
        cat > "$out.base" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cirrus Photos</title>
    <link>$SITE_URL/</link>
    <description>Cirrus Photos updates</description>
    <language>en</language>
  </channel>
</rss>
EOF
    fi
    grep -q '</channel>' "$out.base" || fail "$appcast has no channel"
    awk -v item="$item_file" '
        !done && (/<item>/ || /<\/channel>/) {
            while ((getline line < item) > 0) print line
            done = 1
        }
        { print }' "$out.base" > "$out"
    rm "$out.base"
    xmllint --noout "$out"
}

cmd_publish() {
    if [[ -n "$(git status --porcelain)" ]]; then
        [[ -n $DRY_RUN && -n $ALLOW_DIRTY ]] || fail "the working tree is not clean"
        echo "warning: dry run from an unclean tree" >&2
    fi
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag already exists"
    if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
        fail "tag $tag already exists on origin"
    fi
    if [[ -z $DRY_RUN ]]; then
        command -v gh >/dev/null || fail "the GitHub CLI (gh) is required"
        gh auth status >/dev/null 2>&1 || fail "gh is not signed in (gh auth login)"
    fi

    cmd_dmg

    step "Tagging and creating the GitHub release"
    run git tag -a "$tag" -m "Cirrus Photos $version"
    # gh would otherwise create the tag on GitHub from the default branch's head.
    run git push origin "refs/tags/$tag"
    run gh release create "$tag" "$dmg" --repo "$GITHUB_REPO" --verify-tag \
        --title "Cirrus Photos $version" --notes-file "$notes_file" --prerelease

    step "Adding the item to $appcast"
    local updated="$release_dir/appcast.xml"
    appcast_with_item "$updated"
    if [[ -n $DRY_RUN ]]; then
        echo "[dry run] would write $appcast as $updated:"
        cat "$updated"
    else
        cp "$updated" "$appcast"
    fi
    run git add "$appcast"
    run git commit -m "Publish Cirrus Photos $version in the appcast"

    cmd_deploy_site

    echo
    [[ -n $DRY_RUN ]] && echo "[dry run] Nothing was published. A real run ends with:"
    echo "Published $tag. The tag is on GitHub; push the appcast commit too:"
    echo "  git push origin HEAD"
}

cmd_deploy_site() {
    step "Deploying website/ to $DEPLOY_HOST:$DEPLOY_PATH/"
    local options=(-av --delete --exclude 'deploy/' --exclude 'README.md' --exclude '.DS_Store')
    [[ -n $DRY_RUN ]] && options+=(--dry-run)
    rsync "${options[@]}" website/ "$DEPLOY_HOST:$DEPLOY_PATH/"
}

case "${1:-}" in
    dmg) cmd_dmg ;;
    publish) cmd_publish ;;
    deploy-site) cmd_deploy_site ;;
    *) echo "Usage: $0 dmg|publish|deploy-site" >&2; exit 2 ;;
esac
