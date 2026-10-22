#!/bin/bash
# Build Shanshuo.app without an Xcode project (FEAT-001 ED-017).
#
# Public source defaults to an ad-hoc development build. A release build must
# explicitly unlock and use the project's existing test-signing identity:
#   CONFIG=release SHANSHUO_SIGNING_DIR=/secure/signing bash scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
OUT="${OUT_DIR:-$MAIN/.work/build}"
CONFIG="${CONFIG:-dev}"
VENDOR="$ROOT/Vendor/sherpa-onnx"
TARGET=arm64-apple-macos14.0
VERSION=0.1.0
BUNDLE_VERSION=1.0.2
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RELEASE_SIGNING_IDENTITY="Shanshuo Test Signing"
OBJ="$OUT/obj"
APP="$OUT/Shanshuo.app"
STAGE="$OUT/.stage/Shanshuo.app"
RESOURCES="$STAGE/Contents/Resources"
DEV_MODEL_DIR=""

case "$CONFIG" in
  dev | release) ;;
  *)
    echo "unsupported CONFIG: $CONFIG" >&2
    exit 2
    ;;
esac

if ! [[ "$BUNDLE_VERSION" =~ ^[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
  echo "invalid CFBundleVersion: $BUNDLE_VERSION" >&2
  exit 2
fi

if [ "$CONFIG" = dev ]; then
  DEV_MODEL_DIR="${SHANSHUO_DEV_MODEL_DIR:-$MAIN/.work/models/qwen3-asr-0.6b-int8}"
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MAIN/.work/clang-module-cache}"
SHANSHUO_VENDOR_CACHE="${SHANSHUO_VENDOR_CACHE:-$MAIN/.work/vendor}" \
  bash "$ROOT/scripts/fetch-vendor.sh" >/dev/null
mkdir -p "$OBJ" "$OUT/.mc" "$CLANG_MODULE_CACHE_PATH"

# 1. Domain core as a static library module (same sources as Packages/ShanshuoCore, tested by
# `swift test`).
swiftc -O -swift-version 6 -target "$TARGET" -module-cache-path "$OUT/.mc" \
  -parse-as-library -module-name ShanshuoCore -emit-library -static -emit-module \
  -emit-module-path "$OBJ/ShanshuoCore.swiftmodule" -o "$OBJ/libShanshuoCore.a" \
  "$ROOT"/Packages/ShanshuoCore/Sources/ShanshuoCore/*.swift

# 2. App bundle. Legal notices are copied before signing so the signature covers them.
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$RESOURCES/licenses"
cp "$ROOT/app/Shanshuo/Models/Qwen3ModelManifest.json" "$RESOURCES/"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$ROOT/licenses/"* "$RESOURCES/licenses/"

cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.arnow117.shanshuo</string>
  <key>CFBundleName</key><string>Shanshuo</string>
  <key>CFBundleDisplayName</key><string>闪说</string>
  <key>CFBundleExecutable</key><string>Shanshuo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>ShanshuoBuildTimestamp</key><string>$BUILD_TIMESTAMP</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>闪说只在你按住快捷键听写或主动开始麦克风测试时使用麦克风，在本机识别成文字。录音不会保存，也不会上传。</string>
EOF

if [ "$CONFIG" = dev ]; then
  cat >> "$STAGE/Contents/Info.plist" <<EOF
  <key>ShanshuoDevModelDir</key><string>$DEV_MODEL_DIR</string>
EOF
fi

cat >> "$STAGE/Contents/Info.plist" <<'EOF'
</dict></plist>
EOF

plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

cat > "$OUT/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF

SRCS=()
while IFS= read -r source; do
  SRCS+=("$source")
done < <(find "$ROOT/app/Shanshuo" -name '*.swift' | sort)

swiftc -O -swift-version 5 -target "$TARGET" -module-cache-path "$OUT/.mc" \
  -module-name Shanshuo -I "$OBJ" -L "$OBJ" -lShanshuoCore \
  -import-objc-header "$ROOT/app/Shanshuo/ASR/Bridging.h" -Xcc -I"$VENDOR/include" \
  -L "$VENDOR/lib" -lsherpa-onnx-c-api -lsherpa-onnx-core -lkaldi-decoder-core \
  -lsherpa-onnx-kaldifst-core -lsherpa-onnx-fstfar -lsherpa-onnx-fst \
  -lkaldi-native-fbank-core -lkissfft-float -lssentencepiece_core -lonnxruntime \
  -lsqlite3 -lc++ -framework AppKit -framework Carbon -framework ApplicationServices \
  -framework AVFoundation -framework Accelerate -framework CoreML -framework CryptoKit \
  -framework Foundation "${SRCS[@]}" -o "$STAGE/Contents/MacOS/Shanshuo"

sign_bundle() {
  local signing_identity
  local signing_keychain=""
  local signing_password_file=""
  local codesign_keychain_args=()

  if [ "$CONFIG" = release ]; then
    signing_identity="${SHANSHUO_SIGNING_IDENTITY:-$RELEASE_SIGNING_IDENTITY}"
    signing_keychain="${SHANSHUO_SIGNING_KEYCHAIN:-${SHANSHUO_SIGNING_DIR:-$MAIN/.work/signing}/shanshuo-signing.keychain-db}"
    signing_password_file="${SHANSHUO_SIGNING_PASSWORD_FILE:-${SHANSHUO_SIGNING_DIR:-$MAIN/.work/signing}/keychain-password}"

    if [ "$signing_identity" != "$RELEASE_SIGNING_IDENTITY" ] \
      || [ ! -r "$signing_keychain" ] \
      || [ ! -r "$signing_password_file" ]; then
      echo "release signing configuration is unavailable" >&2
      exit 2
    fi

    security unlock-keychain -p "$(cat "$signing_password_file")" "$signing_keychain"
    codesign_keychain_args=(--keychain "$signing_keychain")
  else
    signing_identity="${SHANSHUO_SIGNING_IDENTITY:--}"
    if [ -n "${SHANSHUO_SIGNING_KEYCHAIN:-}" ]; then
      codesign_keychain_args=(--keychain "$SHANSHUO_SIGNING_KEYCHAIN")
    fi
  fi

  if [ "${#codesign_keychain_args[@]}" -eq 0 ]; then
    codesign --force --options runtime --entitlements "$OUT/entitlements.plist" \
      --sign "$signing_identity" "$STAGE"
  else
    codesign --force --options runtime --entitlements "$OUT/entitlements.plist" \
      --sign "$signing_identity" "${codesign_keychain_args[@]}" "$STAGE"
  fi
}

sign_bundle
codesign --verify --deep --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "built $APP ($CONFIG, $VERSION/$BUNDLE_VERSION, $BUILD_TIMESTAMP)"
