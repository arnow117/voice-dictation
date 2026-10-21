#!/bin/bash
# Build and sign ShanshuoProbe.app with the stable "Shanshuo Test Signing" identity (FEAT-001 ED-012).
#   bash spikes/platform/ShanshuoProbe/build.sh            -> $OUT_DIR/ShanshuoProbe.app
# Every build gets a new ProbeBuildID so the log shows whether permissions survive a rebuild.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=/Users/arnow117/hansen_agent_team/workspace/20261021-voice-dictation
OUT_DIR="${OUT_DIR:-$ROOT/.work/t002}"
SIGN_DIR="$ROOT/.work/signing"
APP="$OUT_DIR/ShanshuoProbe.app"
# Build into a staging bundle and swap it in, so a running copy is never overwritten in place.
STAGE="$OUT_DIR/.stage/ShanshuoProbe.app"
BUILD_ID="$(date +%Y%m%d-%H%M%S)"
LOG_PATH="$OUT_DIR/probe-log.jsonl"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$OUT_DIR/.mc"
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.arnow117.shanshuo.probe</string>
  <key>CFBundleName</key><string>ShanshuoProbe</string>
  <key>CFBundleDisplayName</key><string>闪说探测</string>
  <key>CFBundleExecutable</key><string>ShanshuoProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$BUILD_ID</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>闪说探测在你按住快捷键时采集麦克风，只计算音量和时长，不保存音频。</string>
  <key>ProbeBuildID</key><string>$BUILD_ID</string>
  <key>ProbeLogPath</key><string>$LOG_PATH</string>
</dict></plist>
EOF

cat > "$OUT_DIR/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$OUT_DIR/.mc" \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework AVFoundation \
  "$HERE/main.swift" -o "$STAGE/Contents/MacOS/ShanshuoProbe"

security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_DIR/shanshuo-signing.keychain-db"
codesign --force --options runtime --entitlements "$OUT_DIR/entitlements.plist" \
  -s "Shanshuo Test Signing" "$STAGE"
codesign --verify --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "built $APP (build $BUILD_ID)"
codesign -d -r- "$APP" 2>&1 | tail -1
