#!/bin/bash
# FEAT-001 ED-012: create the long-lived self-signed code signing identity "Shanshuo Test Signing".
#
# The identity lives in a dedicated keychain file outside the repository, so the user's login
# keychain is not touched and codesign never shows a keychain access prompt:
#   $SIGN_DIR/shanshuo-signing.keychain-db   (password in $SIGN_DIR/keychain-password, mode 600)
# A stable identity lets macOS keep the Microphone/Accessibility grants across rebuilds.
# Back up $SIGN_DIR yourself; losing it means testers have to grant permissions again.
set -euo pipefail

SIGN_DIR="${SIGN_DIR:-/Users/arnow117/hansen_agent_team/workspace/20261021-voice-dictation/.work/signing}"
NAME="Shanshuo Test Signing"
KC="$SIGN_DIR/shanshuo-signing.keychain-db"

if [ -f "$KC" ]; then
  echo "keychain already exists: $KC"
  security find-identity -p codesigning "$KC"
  exit 0
fi

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"
umask 077
KC_PASS=$(openssl rand -hex 24)
P12_PASS=$(openssl rand -hex 24)
printf '%s' "$KC_PASS" > "$SIGN_DIR/keychain-password"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Shanshuo Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 10 years; RSA 2048 is what codesign expects from a self-signed identity
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$SIGN_DIR/shanshuo-test-signing.cer.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$SIGN_DIR/shanshuo-test-signing.cer.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12_PASS" 2>/dev/null || \
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$SIGN_DIR/shanshuo-test-signing.cer.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12_PASS"

security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

echo "created $KC"
openssl x509 -in "$SIGN_DIR/shanshuo-test-signing.cer.pem" -noout -subject -enddate -fingerprint -sha256
security find-identity -p codesigning "$KC"
