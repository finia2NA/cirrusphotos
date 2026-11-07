#!/bin/bash
# Sets up the self-signed "Cirrus Photos" code-signing certificate in the login keychain: creates
# it once (backup in the gitignored secrets/cirrus-photos-signing.p12), restores it from that
# backup on another Mac, and trusts it for code signing, which macOS confirms with your password.
# Keep the .p12 and its password with the Sparkle key: builds signed with another certificate
# cannot update existing installs.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

p12=secrets/cirrus-photos-signing.p12
keychain="$HOME/Library/Keychains/login.keychain-db"
# LibreSSL writes PKCS#12 files that `security import` reads; Homebrew's OpenSSL 3+ does not by default.
openssl=/usr/bin/openssl
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if security find-identity -v -p codesigning | grep -q "\"$SIGNING_NAME\""; then
    echo "The \"$SIGNING_NAME\" signing certificate is already set up."
    exit 0
fi

if security find-identity -p codesigning | grep -q "\"$SIGNING_NAME\""; then
    echo "The \"$SIGNING_NAME\" certificate is in the keychain but not trusted for code signing."
    security find-certificate -c "$SIGNING_NAME" -p "$keychain" > "$work/cert.pem"
elif [[ -f $p12 ]]; then
    echo "Restoring the \"$SIGNING_NAME\" certificate from $p12."
    read -rsp "Password of $p12: " password; echo
    security import "$p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
    "$openssl" pkcs12 -in "$p12" -passin "pass:$password" -nokeys -out "$work/cert.pem"
else
    echo "Creating the \"$SIGNING_NAME\" certificate (valid for 20 years) and its backup $p12."
    read -rsp "Choose a password for the backup: " password; echo
    read -rsp "Repeat the password: " repeated; echo
    [[ -n $password && $password == "$repeated" ]] || { echo "The passwords are empty or differ." >&2; exit 1; }
    cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $SIGNING_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    "$openssl" req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    mkdir -p secrets
    "$openssl" pkcs12 -export -name "$SIGNING_NAME" -inkey "$work/key.pem" -in "$work/cert.pem" \
        -passout "pass:$password" -out "$p12"
    chmod 600 "$p12"
    security import "$p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
fi

echo "Trusting the certificate for code signing; macOS asks for your password."
security add-trusted-cert -p codeSign -k "$keychain" "$work/cert.pem"
security find-identity -v -p codesigning | grep -q "\"$SIGNING_NAME\"" ||
    { echo "The certificate is still not a valid signing identity." >&2; exit 1; }
echo "Done. The first build asks once for keychain access to the key; choose Always Allow."
[[ -f $p12 ]] && echo "Back up $p12 and its password."
