#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/input-device-selection-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  "$ROOT/app/Shanshuo/Platform/InputDeviceSelection.swift" \
  "$ROOT/tests/integration/input_device_selection_harness.swift" \
  -o "$OUT"
"$OUT"
