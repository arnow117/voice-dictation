#!/bin/bash
# One-shot checks for Shanshuo (FEAT-001 ED-017): domain unit tests, app build, ASR smoke test.
#   bash scripts/test.sh            # all
#   SKIP_ASR=1 bash scripts/test.sh # without the model (CI-like machines)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$WORK/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "== unit tests (Packages/ShanshuoCore)"
swift test --package-path "$ROOT/Packages/ShanshuoCore" --scratch-path "$WORK/spm/core" --disable-sandbox 2>&1 \
  | grep -E "^(✔|✘)|passed|failed|error:" | grep -v "^✔ Test \"" || true
swift test --package-path "$ROOT/Packages/ShanshuoCore" --scratch-path "$WORK/spm/core" --disable-sandbox >/dev/null 2>&1

echo "== build"
bash "$ROOT/scripts/build.sh"

echo "== coordinator harness"
bash "$ROOT/tests/integration/run_coordinator_harness.sh"

echo "== hotkey configuration harness"
bash "$ROOT/tests/integration/run_hotkey_configuration_harness.sh"

echo "== text inserter harness"
bash "$ROOT/tests/integration/run_text_inserter_harness.sh"

echo "== screen geometry harness"
bash "$ROOT/tests/integration/run_screen_geometry_harness.sh"

echo "== chunk decoder harness"
bash "$ROOT/tests/integration/run_chunk_decoder_harness.sh"

echo "== history store harness"
bash "$ROOT/tests/integration/run_history_store_harness.sh"

echo "== history failure state harness"
bash "$ROOT/tests/integration/run_history_failure_state_harness.sh"

echo "== input device selection harness"
bash "$ROOT/tests/integration/run_input_device_selection_harness.sh"

echo "== queued audio operation lease harness"
bash "$ROOT/tests/integration/run_queued_audio_operation_lease_harness.sh"

echo "== onboarding and pause state harness"
bash "$ROOT/tests/integration/run_onboarding_state_harness.sh"

echo "== native window construction harness"
bash "$ROOT/tests/integration/run_native_window_construction_harness.sh"

echo "== ASR cancellation harness"
bash "$ROOT/tests/integration/run_asr_cancellation_harness.sh"

echo "== model manager harness"
bash "$ROOT/tests/integration/run_model_manager_harness.sh"

echo "== model downloader harness"
bash "$ROOT/tests/integration/run_model_downloader_harness.sh"

echo "== model downloader local HTTP harness"
bash "$ROOT/tests/integration/run_model_downloader_http_harness.sh"

if [ "${SKIP_ASR:-0}" != 1 ]; then
  echo "== ASR smoke (app --transcribe, model $WORK/models/qwen3-asr-0.6b-int8)"
  SHANSHUO_MODEL_DIR="$WORK/models/qwen3-asr-0.6b-int8" UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}" \
    uv run --project "$ROOT/bench/asr" python "$ROOT/tests/integration/asr_smoke.py" \
    "$WORK/build/Shanshuo.app/Contents/MacOS/Shanshuo" "$WORK/bench-data/clips"
  echo "== ASR bounded chunk runtime"
  SHANSHUO_MODEL_DIR="$WORK/models/qwen3-asr-0.6b-int8" \
    python3 "$ROOT/tests/integration/asr_chunking_runtime.py" \
    "$WORK/build/Shanshuo.app/Contents/MacOS/Shanshuo" "$WORK/bench-data/clips"
fi
echo "== all checks passed"
