#!/bin/bash
# T001 timing runs for Shanshuo (FEAT-001). Run this in your own Terminal.app, not inside Manus:
#   bash /Users/arnow117/hansen_agent_team/workspace/20261021-voice-dictation/.worktrees/feat-FEAT-001/bench/asr/run_terminal.sh
#
# Why: processes started by the Manus agent are confined to the efficiency cores on this Mac,
# so recognition there is 2-3x slower than in a normal foreground app. Accuracy is measured by
# the agent; this script measures latency (4 models), Qwen3-ASR thread counts and CoreML.
# Takes about 15-25 minutes. Keep the Mac plugged in; other light work is fine.
set -euo pipefail

ROOT=/Users/arnow117/hansen_agent_team/workspace/20261021-voice-dictation
WT="$ROOT/.worktrees/feat-FEAT-001"
WORK="$ROOT/.work"
LOCK="$WORK/bench-agent.lock"
OUT="$WT/bench/asr/results/terminal"

cd "$WT"
while [ -f "$LOCK" ]; do
  echo "$(date +%H:%M:%S) 等待 Manus 中的准确率评测结束（$LOCK 存在）……"
  sleep 30
done

echo "$(date +%H:%M:%S) 开始计时测试，结果写入 $OUT"
caffeinate -i uv run --project bench/asr python bench/asr/run_bench.py all --suite terminal \
  --models "$WORK/models" --data "$WORK/bench-data" --results "$OUT" 2>&1 | tee "$WORK/bench-terminal.log"

echo
echo "$(date +%H:%M:%S) 全部完成。可以回到 Manus 说一声“跑完了”。"
