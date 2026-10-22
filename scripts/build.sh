#!/bin/bash
# Build and sign Shanshuo.app without an Xcode project (FEAT-001 ED-017).
#   bash scripts/build.sh                 -> <main checkout>/.work/build/Shanshuo.app (dev build)
#   CONFIG=release bash scripts/build.sh  -> no dev model path baked in (T016 packaging)
# Signs with the stable "Shanshuo Test Signing" identity (ED-012) so TCC grants survive rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"                      # main checkout; shared .work lives there
OUT="${OUT_DIR:-$MAIN/.work/build}"
CONFIG="${CONFIG:-dev}"
SIGN_DIR="$MAIN/.work/signing"
VENDOR="$ROOT/Vendor/sherpa-onnx"
TARGET=arm64-apple-macos14.0
BUILD_ID="$(date +%Y%m%d-%H%M%S)"
OBJ="$OUT/obj"
APP="$OUT/Shanshuo.app"
STAGE="$OUT/.stage/Shanshuo.app"
DEV_MODEL_DIR=""
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MAIN/.work/clang-module-cache}"
[ "$CONFIG" = dev ] && DEV_MODEL_DIR="$MAIN/.work/models/qwen3-asr-0.6b-int8"

SHANSHUO_VENDOR_CACHE="${SHANSHUO_VENDOR_CACHE:-$MAIN/.work/vendor}" bash "$ROOT/scripts/fetch-vendor.sh" >/dev/null
mkdir -p "$OBJ" "$OUT/.mc" "$CLANG_MODULE_CACHE_PATH"

# 1. Domain core as a static library module (same sources as Packages/ShanshuoCore, tested by `swift test`).
swiftc -O -swift-version 6 -target $TARGET -module-cache-path "$OUT/.mc" -parse-as-library \
  -module-name ShanshuoCore -emit-library -static -emit-module -emit-module-path "$OBJ/ShanshuoCore.swiftmodule" \
  -o "$OBJ/libShanshuoCore.a" "$ROOT"/Packages/ShanshuoCore/Sources/ShanshuoCore/*.swift

# 2. App bundle.
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$ROOT/app/Shanshuo/Models/Qwen3ModelManifest.json" "$STAGE/Contents/Resources/"
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.arnow117.shanshuo</string>
  <key>CFBundleName</key><string>Shanshuo</string>
  <key>CFBundleDisplayName</key><string>闪说</string>
  <key>CFBundleExecutable</key><string>Shanshuo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$BUILD_ID</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>闪说只在你按住快捷键时使用麦克风，把你说的话在本机识别成文字。录音不会保存，也不会上传。</string>
  <key>ShanshuoDevModelDir</key><string>$DEV_MODEL_DIR</string>
</dict></plist>
EOF
cat > "$OUT/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF

SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$ROOT/app/Shanshuo" -name '*.swift' | sort)
swiftc -O -swift-version 5 -target $TARGET -module-cache-path "$OUT/.mc" -module-name Shanshuo \
  -I "$OBJ" -L "$OBJ" -lShanshuoCore \
  -import-objc-header "$ROOT/app/Shanshuo/ASR/Bridging.h" -Xcc -I"$VENDOR/include" \
  -L "$VENDOR/lib" -lsherpa-onnx-c-api -lsherpa-onnx-core -lkaldi-decoder-core -lsherpa-onnx-kaldifst-core \
  -lsherpa-onnx-fstfar -lsherpa-onnx-fst -lkaldi-native-fbank-core -lkissfft-float -lssentencepiece_core \
  -lonnxruntime -lc++ \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework AVFoundation \
  -framework Accelerate -framework CoreML -framework CryptoKit -framework Foundation \
  "${SRCS[@]}" -o "$STAGE/Contents/MacOS/Shanshuo"

security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_DIR/shanshuo-signing.keychain-db"
codesign --force --options runtime --entitlements "$OUT/entitlements.plist" -s "Shanshuo Test Signing" "$STAGE"
codesign --verify --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "built $APP (build $BUILD_ID, $CONFIG)"
