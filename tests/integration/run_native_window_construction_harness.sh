#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/native-window-construction-harness"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$WORK/build/.mc" \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon \
  -framework AudioToolbox -framework CoreAudio -framework CryptoKit \
  -I "$WORK/build/obj" -L "$WORK/build/obj" -lShanshuoCore -lsqlite3 \
  "$ROOT/app/Shanshuo/App/AppModel.swift" \
  "$ROOT/app/Shanshuo/App/DeferredActionGate.swift" \
  "$ROOT/app/Shanshuo/App/OnboardingProgress.swift" \
  "$ROOT/app/Shanshuo/App/OperationFailureState.swift" \
  "$ROOT/app/Shanshuo/App/PauseController.swift" \
  "$ROOT/app/Shanshuo/App/Paths.swift" \
  "$ROOT/app/Shanshuo/App/PracticeSessionState.swift" \
  "$ROOT/app/Shanshuo/App/SoundPreference.swift" \
  "$ROOT/app/Shanshuo/Performance/PerformanceDiagnostics.swift" \
  "$ROOT/app/Shanshuo/Coordinator/DictationCoordinator.swift" \
  "$ROOT/app/Shanshuo/History/HistoryStore.swift" \
  "$ROOT/app/Shanshuo/Models/ModelFileDownloader.swift" \
  "$ROOT/app/Shanshuo/Models/ModelManager.swift" \
  "$ROOT/app/Shanshuo/Models/ModelManifest.swift" \
  "$ROOT/app/Shanshuo/Models/Qwen3ModelFiles.swift" \
  "$ROOT/app/Shanshuo/Platform/AudioEngineEvents.swift" \
  "$ROOT/app/Shanshuo/Platform/InputDeviceSelection.swift" \
  "$ROOT/app/Shanshuo/Platform/HotkeyConfiguration.swift" \
  "$ROOT/app/Shanshuo/Platform/MemoryAudioCapture.swift" \
  "$ROOT/app/Shanshuo/Platform/QueuedAudioOperationLease.swift" \
  "$ROOT/app/Shanshuo/Platform/SystemState.swift" \
  "$ROOT/app/Shanshuo/Platform/TextInsertionOperation.swift" \
  "$ROOT/app/Shanshuo/Platform/TextInserter.swift" \
  "$ROOT/app/Shanshuo/Formatting/FormattingService.swift" \
  "$ROOT/app/Shanshuo/Formatting/FormattingConfigurationStore.swift" \
  "$ROOT/app/Shanshuo/Formatting/FormattingCredentialStore.swift" \
  "$ROOT/app/Shanshuo/Formatting/CCSwitchMiniMaxImporter.swift" \
  "$ROOT/app/Shanshuo/UI/FormattingSettingsWindowController.swift" \
  "$ROOT/app/Shanshuo/UI/HistoryWindowController.swift" \
  "$ROOT/app/Shanshuo/UI/ModelManagementWindowController.swift" \
  "$ROOT/app/Shanshuo/UI/OnboardingWindowController.swift" \
  "$ROOT/app/Shanshuo/UI/PracticeTextView.swift" \
  "$ROOT/app/Shanshuo/UI/PrivacyWindowController.swift" \
  "$ROOT/app/Shanshuo/UI/SettingsWindowController.swift" \
  "$ROOT/tests/integration/native_window_construction_harness.swift" \
  -o "$OUT"
"$OUT"
