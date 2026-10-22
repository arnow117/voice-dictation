#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/onboarding-state-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  "$ROOT/app/Shanshuo/App/DeferredActionGate.swift" \
  "$ROOT/app/Shanshuo/App/PauseController.swift" \
  "$ROOT/app/Shanshuo/App/PauseMenuPresentation.swift" \
  "$ROOT/app/Shanshuo/App/OnboardingProgress.swift" \
  "$ROOT/app/Shanshuo/App/PracticeSessionState.swift" \
  "$ROOT/tests/integration/onboarding_state_harness.swift" \
  -o "$OUT"
"$OUT"
