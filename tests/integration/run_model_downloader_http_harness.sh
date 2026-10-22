#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON")"
WORK="$MAIN/.work"
OUT="$WORK/build/model-downloader-http-harness"
PORT_FILE="$(mktemp -t shanshuo-model-http-port)"

cleanup() {
  kill "$FIXTURE_PID" 2>/dev/null || true
  wait "$FIXTURE_PID" 2>/dev/null || true
  rm -f "$PORT_FILE"
}

python3 "$ROOT/tests/integration/model_downloader_http_fixture.py" "$PORT_FILE" &
FIXTURE_PID=$!
trap cleanup EXIT

for _ in {1..20}; do
  [ -s "$PORT_FILE" ] && break
  sleep 0.05
done
[ -s "$PORT_FILE" ]
FIXTURE_PORT="$(cat "$PORT_FILE")"

swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$WORK/build/.mc" \
  "$ROOT/app/Shanshuo/Models/ModelFileDownloader.swift" \
  "$ROOT/tests/integration/model_downloader_http_harness.swift" \
  -o "$OUT"
SHANSHUO_MODEL_FIXTURE_BASE_URL="http://127.0.0.1:$FIXTURE_PORT" "$OUT"
