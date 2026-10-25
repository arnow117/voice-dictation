#!/bin/bash
# Assemble reproducible local beta assets. It only clears its own staging/output files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="v0.1.0-beta.2"
ASSET_PREFIX="Shanshuo-${VERSION}-macos-arm64"
DIST_DIRECTORY="${DIST_DIR:-$ROOT/.work/dist/$VERSION}"
STAGING_DIRECTORY="$DIST_DIRECTORY/.staging"
BUILD_DIRECTORY="$STAGING_DIRECTORY/build"
ZIP_ROOT="$STAGING_DIRECTORY/Shanshuo-$VERSION"
DMG_ROOT="$STAGING_DIRECTORY/dmg-root"
ZIP_PATH="$DIST_DIRECTORY/$ASSET_PREFIX.zip"
DMG_PATH="$DIST_DIRECTORY/$ASSET_PREFIX.dmg"
CHECKSUM_PATH="$DIST_DIRECTORY/SHA256SUMS.txt"

copy_distribution_documents() {
  local destination="$1"

  mkdir -p "$destination/docs/release-notes" "$destination/docs/validation" \
    "$destination/bench/asr/results/production" "$destination/bench/formatting/v1" \
    "$destination/licenses"
  cp "$ROOT/docs/install.md" "$destination/docs/install.md"
  cp "$ROOT/docs/known-issues.md" "$destination/docs/known-issues.md"
  cp "$ROOT/docs/compatibility.md" "$destination/docs/compatibility.md"
  cp "$ROOT/docs/release-notes/v0.1.0-beta.2.md" \
    "$destination/docs/release-notes/v0.1.0-beta.2.md"
  cp "$ROOT/docs/validation/asr-rms-fix-125650.md" \
    "$destination/docs/validation/asr-rms-fix-125650.md"
  cp "$ROOT/docs/validation/asr-7b64a10.md" \
    "$destination/docs/validation/asr-7b64a10.md"
  cp "$ROOT/docs/validation/minimax-formatting-v2.md" \
    "$destination/docs/validation/minimax-formatting-v2.md"
  cp "$ROOT/bench/asr/testset.jsonl" "$destination/bench/asr/testset.jsonl"
  cp "$ROOT/bench/asr/results/production/rms-fix-125650.jsonl" \
    "$destination/bench/asr/results/production/rms-fix-125650.jsonl"
  cp "$ROOT/bench/asr/results/production/rms-fix-125650.summary.json" \
    "$destination/bench/asr/results/production/rms-fix-125650.summary.json"
  cp "$ROOT/bench/asr/results/production/7b64a10.jsonl" \
    "$destination/bench/asr/results/production/7b64a10.jsonl"
  cp "$ROOT/bench/asr/results/production/7b64a10.summary.json" \
    "$destination/bench/asr/results/production/7b64a10.summary.json"
  cp "$ROOT/bench/formatting/heldout.jsonl" "$destination/bench/formatting/heldout.jsonl"
  cp "$ROOT/bench/formatting/freeze.json" "$destination/bench/formatting/freeze.json"
  cp "$ROOT/bench/formatting/rubric.json" "$destination/bench/formatting/rubric.json"
  cp "$ROOT/bench/formatting/scorer.py" "$destination/bench/formatting/scorer.py"
  cp "$ROOT/bench/formatting/v1/"* "$destination/bench/formatting/v1/"
  cp "$ROOT/LICENSE" "$destination/LICENSE"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$destination/THIRD_PARTY_NOTICES.md"
  cp "$ROOT/licenses/"* "$destination/licenses/"
  cat > "$destination/README.md" <<'EOF'
# 闪说 v0.1.0-beta.2 本地候选

- [安装说明](docs/install.md)
- [已知问题](docs/known-issues.md)
- [测试版说明](docs/release-notes/v0.1.0-beta.2.md)
EOF
}

mkdir -p "$DIST_DIRECTORY"
rm -rf "$STAGING_DIRECTORY"
rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
mkdir -p "$BUILD_DIRECTORY" "$ZIP_ROOT" "$DMG_ROOT"

CONFIG=release OUT_DIR="$BUILD_DIRECTORY" bash "$ROOT/scripts/build.sh"
REQUIRE_RELEASE_SIGNING=1 bash "$ROOT/scripts/release/verify_bundle.sh" \
  "$BUILD_DIRECTORY/Shanshuo.app"

ditto "$BUILD_DIRECTORY/Shanshuo.app" "$ZIP_ROOT/Shanshuo.app"
copy_distribution_documents "$ZIP_ROOT"
ditto -c -k --sequesterRsrc --keepParent "$ZIP_ROOT" "$ZIP_PATH"

ditto "$BUILD_DIRECTORY/Shanshuo.app" "$DMG_ROOT/Shanshuo.app"
copy_distribution_documents "$DMG_ROOT"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -ov -volname "Shanshuo $VERSION" -srcfolder "$DMG_ROOT" -format UDZO "$DMG_PATH" >/dev/null

(
  cd "$DIST_DIRECTORY"
  shasum -a 256 "$(basename "$ZIP_PATH")" "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

bash "$ROOT/scripts/release/verify_archives.sh" "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
echo "release assets: $DIST_DIRECTORY"
