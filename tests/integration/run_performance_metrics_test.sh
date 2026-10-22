#!/bin/bash
# Validates the report tool's production event schema and failed/incomplete-sample behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
HARNESS="$WORK/build/performance-diagnostics-harness"
bash "$ROOT/tests/integration/run_performance_diagnostics_harness.sh"

FIXTURE_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIRECTORY"' EXIT
FIXTURE_PATH="$FIXTURE_DIRECTORY/performance-production.jsonl"
FOCUS_FIXTURE_PATH="$FIXTURE_DIRECTORY/performance-focus-production.jsonl"
"$HARNESS" --emit-jsonl "$FIXTURE_PATH"
"$HARNESS" --emit-focus-jsonl "$FOCUS_FIXTURE_PATH"
SHANSHUO_SWIFT_EVENT_JSONL="$FIXTURE_PATH" \
SHANSHUO_SWIFT_FOCUS_EVENT_JSONL="$FOCUS_FIXTURE_PATH" \
  python3 "$ROOT/tests/integration/performance_metrics_test.py"
