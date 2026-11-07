# Sourced by run.sh, profile.sh and release.sh. Every build is signed with the self-signed
# "Cirrus Photos" certificate from scripts/make-signing-cert.sh. Sparkle installs an update only
# when it is signed by the same identity as the installed app, and macOS ties Keychain access to
# it, so the certificate must not change once a release is out. CODESIGN_IDENTITY overrides.
SIGNING_NAME="Cirrus Photos"

# Prints the identity to sign with, or nothing when the certificate is missing or untrusted.
signing_identity() {
    if [[ -n ${CODESIGN_IDENTITY:-} ]]; then
        echo "$CODESIGN_IDENTITY"
    elif security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGNING_NAME\""; then
        echo "$SIGNING_NAME"
    fi
}
