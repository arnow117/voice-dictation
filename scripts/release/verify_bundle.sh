#!/bin/bash
# Verify a Shanshuo bundle before it is copied into a beta archive.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/Shanshuo.app" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$1"
INFO_PLIST="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"
EXECUTABLE="$APP/Contents/MacOS/Shanshuo"
REQUIRE_RELEASE_SIGNING="${REQUIRE_RELEASE_SIGNING:-0}"

fail() {
  echo "bundle verification failed: $1" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

[ -d "$APP" ] || fail "app bundle is missing"
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing"
[ -x "$EXECUTABLE" ] || fail "executable is missing"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
codesign --verify --deep --strict "$APP" || fail "code signature is invalid"
signature_details="$(codesign -dvvv "$APP" 2>&1)"
printf '%s\n' "$signature_details" | grep -Fq "runtime" \
  || fail "Hardened Runtime is missing"
entitlements="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
printf '%s\n' "$entitlements" | grep -Fq "com.apple.security.device.audio-input" \
  || fail "audio-input entitlement is missing"

[ "$(plist_value CFBundleIdentifier)" = "com.arnow117.shanshuo" ] \
  || fail "unexpected bundle identifier"
[ "$(plist_value CFBundleShortVersionString)" = "0.1.0" ] \
  || fail "unexpected short version"
BUNDLE_VERSION="$(plist_value CFBundleVersion)"
[[ "$BUNDLE_VERSION" =~ ^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] \
  || fail "invalid bundle version"
[ -n "$(plist_value ShanshuoBuildTimestamp)" ] || fail "missing build timestamp"

if /usr/libexec/PlistBuddy -c "Print :ShanshuoDevModelDir" "$INFO_PLIST" >/dev/null 2>&1; then
  fail "release bundle contains a development model directory"
fi

[ -f "$RESOURCES/LICENSE" ] || fail "MIT license is missing"
[ -f "$RESOURCES/THIRD_PARTY_NOTICES.md" ] || fail "third-party notices are missing"
LICENSE_COUNT="$(find "$RESOURCES/licenses" -maxdepth 1 -type f | wc -l | tr -d ' ')"
[ "$LICENSE_COUNT" = "17" ] || fail "expected 17 third-party license files"

if find "$RESOURCES" -type f \( -name '*.onnx' -o -name '*.wav' \) -print -quit | grep -q .; then
  fail "release bundle contains a model weight or audio fixture"
fi

if grep -a -R -F -q "$ROOT/" "$APP"; then
  fail "release bundle contains a source checkout path"
fi

ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
case " $ARCHITECTURES " in
  *" arm64 "*) ;;
  *) fail "arm64 executable is missing" ;;
esac

dependencies="$(otool -L "$EXECUTABLE" | tail -n +2 | awk '{print $1}')"
while IFS= read -r dependency; do
  [ -z "$dependency" ] && continue
  case "$dependency" in
    /System/Library/* | /usr/lib/*) ;;
    *) fail "non-system dynamic dependency" ;;
  esac
done <<< "$dependencies"

if [ "$REQUIRE_RELEASE_SIGNING" = 1 ]; then
  printf '%s\n' "$signature_details" | grep -Fq "Authority=Shanshuo Test Signing" \
    || fail "release signing identity is missing"
fi

echo "bundle: $APP"
echo "architectures: $ARCHITECTURES"
echo "dynamic dependencies:"
printf '%s\n' "$dependencies"
