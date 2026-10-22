"""ASR smoke test for the built app: run `Shanshuo --transcribe` on 2 clips per category and check error rates.

    uv run --project bench/asr python tests/integration/asr_smoke.py <Shanshuo binary> <clips dir>

Uses the same scoring as the T001 bench (bench/asr/textnorm.py, relaxed). Thresholds are loose smoke
limits (catch a broken build or wrong feature config), not the NFR-003 targets.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bench" / "asr"))
import textnorm as tn  # noqa: E402

CLIPS = {"zh": ["zh-001", "zh-002"], "en": ["en-001", "en-002"], "mixed": ["mixed-001", "mixed-002"],
         "entity": ["entity-001", "entity-002"]}
LIMIT = {"zh": 0.15, "en": 0.15, "mixed": 0.30, "entity": 0.15}


def main():
    binary, clips = sys.argv[1], Path(sys.argv[2])
    refs = {}
    for line in (ROOT / "bench" / "asr" / "testset.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        refs[r["id"]] = r["text"]
    ids = [i for v in CLIPS.values() for i in v]
    out = subprocess.run([binary, "--transcribe", *[str(clips / f"{i}.wav") for i in ids]],
                         capture_output=True, text=True, timeout=600)
    rows = [json.loads(l) for l in out.stdout.splitlines() if l.startswith("{")]
    by_file = {r["file"][:-4]: r for r in rows if "file" in r}
    failed = False
    if out.returncode != 0 or len(by_file) != len(ids):
        print(f"FAIL: exit {out.returncode}, {len(by_file)}/{len(ids)} results")
        sys.exit(1)
    for cat, cids in CLIPS.items():
        hyps = [by_file[i]["text"] for i in cids]
        rate = tn.error_rate([refs[i] for i in cids], hyps, relaxed=True)
        empty = sum(1 for h in hyps if not h.strip())
        ok = rate <= LIMIT[cat] and empty == 0
        failed |= not ok
        rtf = max(by_file[i]["rtf"] for i in cids)
        print(f"{'ok  ' if ok else 'FAIL'} {cat:7s} error {rate:.1%} (limit {LIMIT[cat]:.0%}), empty {empty}, max rtf {rtf}")
    load = next(r for r in rows if r.get("event") == "loaded")
    done = next(r for r in rows if r.get("event") == "done")
    print(f"load {load['load_s']} s, rss after load {load['rss_mb']} MB, after decode {done['rss_mb']} MB")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
