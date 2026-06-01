#!/bin/bash
# Create a stable self-signed code-signing identity so macOS TCC permission
# grants (Microphone, Accessibility, etc.) survive rebuilds. Run once.
#
# Without a stable identity, ad-hoc signing changes the code hash every build and
# macOS re-prompts for every permission. A persistent self-signed cert keeps the
# app's identity constant.
#
# We import the key and certificate SEPARATELY rather than via a PKCS#12 (.p12)
# bundle: Homebrew's OpenSSL 3 writes .p12 files with a MAC that macOS's `security`
# tool rejects ("MAC verification failed / wrong password"). Separate import avoids
# that container entirely.
set -euo pipefail

IDENTITY_NAME="Murmur Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Note: we check WITHOUT -v. A self-signed cert is "not trusted", which -v hides,
# but codesign can still sign with it and that's all we need.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Code-signing identity '$IDENTITY_NAME' already present. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY_NAME'..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $IDENTITY_NAME
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Generate key + self-signed cert (quietly).
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -days 3650 \
    -config "$TMP/cert.conf" >/dev/null 2>&1

# Import certificate, then private key. The -A flag lets all apps use the key
# without a per-use prompt; without it, codesign fails with errSecInternalComponent
# (it can't reach the CLI-imported key) and silently falls back to ad-hoc signing.
security import "$TMP/cert.pem" -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null
security import "$TMP/key.pem"  -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Success. '$IDENTITY_NAME' is ready for code signing."
    echo "(It shows as 'not trusted', which is expected and fine for a local app;"
    echo " codesign uses it anyway and your permission grants will persist.)"
    echo "Now run: ./scripts/build.sh   (it uses this identity automatically)"
else
    echo "Import finished but no codesigning identity was created."
    echo "Check with:  security find-identity -p codesigning"
    exit 1
fi
