#!/bin/bash
# Exercises the production SystemTextInserter with a deterministic scheduler, fake clipboard, and
# fake event poster. It never posts Command-V or writes the user's actual pasteboard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/text-inserter-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$WORK/build/.mc" \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore \
  -framework AppKit -framework Carbon -framework ApplicationServices \
  "$ROOT/app/Shanshuo/Platform/HotkeyConfiguration.swift" \
  "$ROOT/app/Shanshuo/Platform/TextInsertionOperation.swift" \
  "$ROOT/app/Shanshuo/Platform/SystemState.swift" \
  "$ROOT/app/Shanshuo/Platform/TextInserter.swift" \
  "$ROOT/tests/integration/text_inserter_harness.swift" \
  -o "$OUT"
"$OUT"
