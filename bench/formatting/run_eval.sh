#!/bin/bash
# Runs the frozen v2 public held-out corpus through the signed production app sequentially.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${SHANSHUO_FORMATTING_EVAL_APP:-$ROOT/.work/minimax/t003-v2-eval-build/Shanshuo.app/Contents/MacOS/Shanshuo}"
RESULTS="${SHANSHUO_FORMATTING_EVAL_RESULTS:-$ROOT/.work/minimax/t003-v2-formal-eval.jsonl}"
SUMMARY="${SHANSHUO_FORMATTING_EVAL_SUMMARY:-$ROOT/.work/minimax/t003-v2-formal-eval.summary.json}"
FREEZE="$ROOT/bench/formatting/freeze.json"

[ -x "$APP" ] || { echo "signed evaluation app is missing: $APP" >&2; exit 2; }
[ ! -e "$RESULTS" ] || { echo "refusing to overwrite evaluation results: $RESULTS" >&2; exit 2; }
python3 - "$ROOT" "$FREEZE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
freeze = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = {
    "formatting_rules_sha256": root / "Packages/ShanshuoCore/Sources/ShanshuoCore/FormattingRules.swift",
    "heldout_fixture_sha256": root / "bench/formatting/heldout.jsonl",
    "rubric_sha256": root / "bench/formatting/rubric.json",
    "scorer_sha256": root / "bench/formatting/scorer.py",
}
if freeze.get("status") != "frozen_before_first_v2_provider_request":
    raise SystemExit("v2 evaluation freeze is not active")
if freeze.get("evaluation_version") != "v2":
    raise SystemExit("evaluation freeze does not name v2")
for key, path in expected.items():
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != freeze.get(key):
        raise SystemExit(f"frozen artifact changed: {path}")
PY
mkdir -p "$(dirname "$RESULTS")" "$(dirname "$SUMMARY")"

cd "$ROOT"
"$APP" --formatting-public-eval --out "$RESULTS"
python3 "$ROOT/bench/formatting/scorer.py" \
  --fixtures "$ROOT/bench/formatting/heldout.jsonl" \
  --results "$RESULTS" \
  --rubric "$ROOT/bench/formatting/rubric.json" \
  --freeze "$FREEZE" \
  --out "$SUMMARY"
