#!/bin/bash
# Uses the production SQLite store with an isolated temporary directory and no app data.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/history-store-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$WORK/build/.mc" \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore -lsqlite3 \
  "$ROOT/app/Shanshuo/History/HistoryStore.swift" \
  "$ROOT/tests/integration/history_store_harness.swift" \
  -o "$OUT"
"$OUT"
