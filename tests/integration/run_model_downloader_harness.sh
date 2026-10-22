#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/model-downloader-harness"

swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$WORK/build/.mc" \
  "$ROOT/app/Shanshuo/Models/ModelFileDownloader.swift" \
  "$ROOT/tests/integration/model_downloader_harness.swift" \
  -o "$OUT"
"$OUT"
