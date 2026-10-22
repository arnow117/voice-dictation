#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
OUT="$MAIN/.work/build/hotkey-configuration-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MAIN/.work/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -framework AVFoundation -framework AppKit -framework ApplicationServices -framework Carbon \
  -I "$MAIN/.work/build/obj" -L "$MAIN/.work/build/obj" -lShanshuoCore \
  "$ROOT/app/Shanshuo/Platform/HotkeyConfiguration.swift" \
  "$ROOT/app/Shanshuo/Platform/SystemState.swift" \
  "$ROOT/tests/integration/hotkey_configuration_harness.swift" \
  -o "$OUT"
"$OUT"
