#!/bin/bash
# One-time setup, run in your own Terminal (the Manus agent cannot change keychain settings):
#   1. add the dedicated signing keychain to your keychain search list (login keychain stays first)
#   2. if codesign still rejects the self-signed identity, mark the certificate as trusted for
#      code signing only (macOS asks for your login password once)
# Nothing is written into your login keychain. Undo: remove the keychain from the list with
#   security list-keychains -d user -s ~/Library/Keychains/login.keychain-db
set -euo pipefail

SIGN_DIR=/Users/arnow117/hansen_agent_team/workspace/20261021-voice-dictation/.work/signing
KC="$SIGN_DIR/shanshuo-signing.keychain-db"
CERT="$SIGN_DIR/shanshuo-test-signing.cer.pem"
NAME="Shanshuo Test Signing"

[ -f "$KC" ] || { echo "missing $KC; run spikes/platform/make-signing-identity.sh first"; exit 1; }

current=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
if ! printf '%s\n' "$current" | grep -qx "$KC"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $current "$KC"
fi
security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$KC"
echo "keychain search list:"
security list-keychains -d user

try_sign() {
  local tmp
  tmp=$(mktemp -d)
  printf 'print("ok")\n' > "$tmp/m.swift"
  swiftc -module-cache-path "$tmp/mc" "$tmp/m.swift" -o "$tmp/probe" >/dev/null 2>&1
  codesign --force --options runtime -s "$NAME" -i com.arnow117.shanshuo.signcheck "$tmp/probe" 2>&1
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

if try_sign; then
  echo "signing works without extra trust settings"
else
  echo "codesign rejected the identity; adding a code-signing-only trust setting (password prompt follows)"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$CERT"
  try_sign && echo "signing works"
fi
security find-identity -v -p codesigning "$KC"
