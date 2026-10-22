#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
OUT="$MAIN/.work/build/queued-audio-operation-lease-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MAIN/.work/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
  -I "$MAIN/.work/build/obj" -L "$MAIN/.work/build/obj" -lShanshuoCore \
  "$ROOT/app/Shanshuo/Platform/AudioEngineEvents.swift" \
  "$ROOT/app/Shanshuo/Platform/InputDeviceSelection.swift" \
  "$ROOT/app/Shanshuo/Platform/QueuedAudioOperationLease.swift" \
  "$ROOT/app/Shanshuo/Platform/MemoryAudioCapture.swift" \
  "$ROOT/tests/integration/queued_audio_operation_lease_harness.swift" \
  -o "$OUT"
"$OUT"
