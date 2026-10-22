#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/asr-cancellation-harness"

swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$WORK/build/.mc" \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore \
  "$ROOT/app/Shanshuo/ASR/Qwen3ChunkDecoder.swift" \
  "$ROOT/app/Shanshuo/ASR/Qwen3ASRService.swift" \
  "$ROOT/tests/integration/asr_cancellation_harness.swift" \
  -o "$OUT"
"$OUT"
