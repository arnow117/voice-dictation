#!/bin/bash
# Validates the report tool's production event schema and failed/incomplete-sample behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$ROOT/tests/integration/performance_metrics_test.py"
