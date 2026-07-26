#!/bin/bash
# Create a local, self-signed code-signing identity for Piko.
#
# Why this exists: TCC (microphone, system audio) remembers a grant by the
# app's *designated requirement*, which an ad-hoc signature does not have — the
# cdhash changes on every build, so macOS treats each rebuild as a brand new
# app and asks for permission again. A stable identity, even a self-signed one,
# keeps the grants across rebuilds.
#
# Run once:  ./scripts/make-signing-cert.sh
# Then:      ./scripts/make-app.sh  (picks the identity up automatically)
#
# macOS will ask for your login password once, to mark the certificate as
# trusted for code signing. Remove it later with:
#   security delete-certificate -c "Piko Dev"
set -euo pipefail

IDENTITY="${PIKO_SIGN_IDENTITY:-Piko Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = $IDENTITY

[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORKDIR/openssl.cnf" \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" 2>/dev/null

openssl pkcs12 -export -legacy \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -name "$IDENTITY" -passout pass:piko -out "$WORKDIR/identity.p12" 2>/dev/null

# -T /usr/bin/codesign: only codesign may use the key without prompting.
# A non-empty passphrase: macOS' PKCS#12 importer rejects empty-password bundles.
security import "$WORKDIR/identity.p12" -k "$KEYCHAIN" -P piko -T /usr/bin/codesign

# Trust it for code signing, otherwise codesign cannot build a chain to it.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"

echo "Created signing identity '$IDENTITY'."
security find-identity -v -p codesigning | grep "$IDENTITY" || true
