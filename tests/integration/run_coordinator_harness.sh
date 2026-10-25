#!/bin/bash
# Runs the production coordinator against explicit fake system adapters. No microphone, model,
# accessibility permission, clipboard, or app UI is involved in this test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/coordinator-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$WORK/build/.mc" \
  -framework AppKit \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore \
  "$ROOT/app/Shanshuo/App/Paths.swift" \
  "$ROOT/app/Shanshuo/Performance/PerformanceDiagnostics.swift" \
  "$ROOT/app/Shanshuo/Platform/HotkeyConfiguration.swift" \
  "$ROOT/app/Shanshuo/Platform/TextInsertionOperation.swift" \
  "$ROOT/app/Shanshuo/Formatting/FormattingService.swift" \
  "$ROOT/app/Shanshuo/Coordinator/DictationCoordinator.swift" \
  "$ROOT/tests/integration/coordinator_harness.swift" \
  -o "$OUT"
"$OUT"
