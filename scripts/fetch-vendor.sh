#!/bin/bash
# Fetch the pinned sherpa-onnx static libraries into Vendor/sherpa-onnx/lib (not committed).
#   bash scripts/fetch-vendor.sh
# Version and checksum are pinned (FEAT-001 技术栈: sherpa-onnx v1.13.8; upgrades get their own Task).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=1.13.8
NAME="sherpa-onnx-v${VERSION}-osx-arm64-static-no-tts-lib"
SHA256=3d7f9b8a496694af13d9802c33b8133231e397bdef302f543d19468765e83136
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
DEST="$ROOT/Vendor/sherpa-onnx/lib"
CACHE="${SHANSHUO_VENDOR_CACHE:-$ROOT/.vendor-cache}"

if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$NAME" ]; then
  echo "vendor ok: $NAME"
  exit 0
fi

mkdir -p "$CACHE"
TARBALL="$CACHE/$NAME.tar.bz2"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | shasum -a 256 -c --status; then
  echo "downloading $URL"
  curl -fL --retry 3 --max-time 600 -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c

rm -rf "$DEST"
mkdir -p "$DEST"
tar xjf "$TARBALL" -C "$CACHE"
cp "$CACHE/$NAME/lib/"*.a "$DEST/"
echo "$NAME" > "$DEST/.version"
echo "vendor installed: $DEST"
ls "$DEST"
