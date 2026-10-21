#!/bin/bash
# One-shot checks for Shanshuo (FEAT-001 ED-017): domain unit tests, app build, ASR smoke test.
#   bash scripts/test.sh            # all
#   SKIP_ASR=1 bash scripts/test.sh # without the model (CI-like machines)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"

echo "== unit tests (Packages/ShanshuoCore)"
swift test --package-path "$ROOT/Packages/ShanshuoCore" --scratch-path "$WORK/spm/core" --disable-sandbox 2>&1 \
  | grep -E "^(✔|✘)|passed|failed|error:" | grep -v "^✔ Test \"" || true
swift test --package-path "$ROOT/Packages/ShanshuoCore" --scratch-path "$WORK/spm/core" --disable-sandbox >/dev/null 2>&1

echo "== build"
bash "$ROOT/scripts/build.sh"

if [ "${SKIP_ASR:-0}" != 1 ]; then
  echo "== ASR smoke (app --transcribe, model $WORK/models/qwen3-asr-0.6b-int8)"
  SHANSHUO_MODEL_DIR="$WORK/models/qwen3-asr-0.6b-int8" UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}" \
    uv run --project "$ROOT/bench/asr" python "$ROOT/tests/integration/asr_smoke.py" \
    "$WORK/build/Shanshuo.app/Contents/MacOS/Shanshuo" "$WORK/bench-data/clips"
fi
echo "== all checks passed"
