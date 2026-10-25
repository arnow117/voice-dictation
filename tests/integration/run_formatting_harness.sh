#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/formatting-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$WORK/build/.mc" \
  -framework Foundation -lsqlite3 \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore \
  "$ROOT/app/Shanshuo/Formatting/FormattingConfigurationStore.swift" \
  "$ROOT/app/Shanshuo/Formatting/FormattingCredentialStore.swift" \
  "$ROOT/app/Shanshuo/Formatting/CCSwitchMiniMaxImporter.swift" \
  "$ROOT/app/Shanshuo/Formatting/FormattingService.swift" \
  "$ROOT/app/Shanshuo/Formatting/MiniMaxFormatter.swift" \
  "$ROOT/tests/integration/formatting_harness.swift" \
  -o "$OUT"
if rg -n 'SecItem(Add|CopyMatching|Delete)|import Security' "$ROOT/app/Shanshuo/Formatting"; then
  echo "MiniMax formatting code must not call the system Keychain" >&2
  exit 1
fi
"$OUT"
