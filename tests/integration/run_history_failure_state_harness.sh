#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
OUT="$MAIN/.work/build/history-failure-state-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MAIN/.work/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 \
  "$ROOT/app/Shanshuo/App/OperationFailureState.swift" \
  "$ROOT/tests/integration/history_failure_state_harness.swift" \
  -o "$OUT"
"$OUT"
