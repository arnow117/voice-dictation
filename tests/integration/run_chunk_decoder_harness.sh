#!/bin/bash
# Drives the production chunk decoder with deterministic digital silence and low-level samples.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/chunk-decoder-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$WORK/build/.mc" \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore \
  "$ROOT/app/Shanshuo/ASR/Qwen3ChunkDecoder.swift" \
  "$ROOT/tests/integration/chunk_decoder_harness.swift" \
  -o "$OUT"
"$OUT"
