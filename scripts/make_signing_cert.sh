#!/usr/bin/env bash
#
# make_signing_cert.sh — create a STABLE self-signed code-signing identity named
# "Koe Signing" in your login keychain.
#
# Why: building the app ad-hoc gives it a new code fingerprint every time, so
# macOS forgets the Accessibility permission on every rebuild. Signing with one
# stable certificate keeps the fingerprint constant, so you grant Accessibility
# ONCE and it survives all future updates.
#
# Run this ONCE:  bash scripts/make_signing_cert.sh
# Then rebuild:   bash scripts/build_app.sh   (it auto-detects and uses the cert)
#
set -euo pipefail

CERT="Koe Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$CERT" >/dev/null 2>&1; then
    echo "✓ '$CERT' already exists — nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing certificate '$CERT'…"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# -legacy so macOS's `security import` can read the PKCS#12 (OpenSSL 3 default is too new).
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/koe.p12" -passout pass:koe -name "$CERT" 2>/dev/null

# -T /usr/bin/codesign pre-authorizes codesign to use the key without prompting.
security import "$TMP/koe.p12" -k "$KEYCHAIN" -P koe -T /usr/bin/codesign -A >/dev/null

echo "✓ Created '$CERT'. Now run: bash scripts/build_app.sh"
echo "  (You'll grant Accessibility ONE more time for the first cert-signed build,"
echo "   then it will stick across all future rebuilds.)"
