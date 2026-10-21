#!/usr/bin/env python3
"""Prepare the T001 dictation test set from public datasets (FEAT-001 T001).

Audio goes to --out (outside the repo); the selection is written to
bench/asr/testset.jsonl so the run is reproducible. Large archives are read as a
stream and the connection is closed once enough clips are collected.

| category | n  | source                              | licence      |
|----------|----|-------------------------------------|--------------|
| zh       | 40 | google/fleurs cmn_hans_cn test      | CC-BY-4.0    |
| en       | 30 | google/fleurs en_us test            | CC-BY-4.0    |
| mixed    | 30 | CAiRE/ASCEND test, language=mixed   | CC-BY-SA-4.0 |
| entity   | 20 | MrSupW/ContextASR-Bench Speech zh   | MIT          |

  uv run --project bench/asr python bench/asr/prepare_data.py --out <dir>
"""
import argparse
import csv
import io
import json
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

HERE = Path(__file__).resolve().parent
UA = {"User-Agent": "shanshuo-bench/0.1"}
HF = "https://huggingface.co/datasets/{repo}/resolve/{rev}/{path}"
REVS = {  # pinned 2026-10-21
    "google/fleurs": "70bb2e84b976",
    "CAiRE/ASCEND": "737e9800ae31",
    "MrSupW/ContextASR-Bench": "7906fd98d1d0",
}
MIN_S, MAX_S = 3.0, 20.0


def url(repo, path):
    return HF.format(repo=repo, rev=REVS[repo], path=path)


def open_url(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=60)


def to_16k_mono(audio, sr):
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != 16000:
        n = int(round(len(audio) * 16000 / sr))
        audio = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio)
    return audio.astype(np.float32)


def save(out, cid, audio, sr):
    audio = to_16k_mono(audio, sr)
    path = out / f"{cid}.wav"
    sf.write(path, audio, 16000, subtype="PCM_16")
    return path, round(len(audio) / 16000, 3)


def fleurs(out, lang, category, n):
    with open_url(url("google/fleurs", f"data/{lang}/test.tsv")) as r:
        rows = list(csv.reader(io.TextIOWrapper(r, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE))
    meta = {}
    for row in rows:
        _id, fname, raw, _norm, _ph, num_samples, gender = row[:7]
        dur = int(num_samples) / 16000
        if MIN_S <= dur <= MAX_S and fname not in meta:
            meta[fname] = {"raw": raw, "gender": gender, "fleurs_id": _id}
    picked, seen_ids = [], set()
    with open_url(url("google/fleurs", f"data/{lang}/audio/test.tar.gz")) as r:
        with tarfile.open(fileobj=r, mode="r|gz") as tar:
            for m in tar:
                name = Path(m.name).name
                if not m.isfile() or name not in meta or meta[name]["fleurs_id"] in seen_ids:
                    continue
                seen_ids.add(meta[name]["fleurs_id"])  # one recording per sentence
                audio, sr = sf.read(io.BytesIO(tar.extractfile(m).read()), dtype="float32")
                cid = f"{category}-{len(picked) + 1:03d}"
                path, dur = save(out, cid, audio, sr)
                picked.append({"id": cid, "category": category, "audio": path.name, "duration": dur,
                               "text": meta[name]["raw"], "entities": [],
                               "source": f"google/fleurs:{lang}/test/{name}", "license": "CC-BY-4.0"})
                if len(picked) == n:
                    break
    return picked


def ascend(out, n):
    cache = out / "_ascend_test.parquet"
    if not cache.exists():
        with open_url(url("CAiRE/ASCEND", "main/test-00000-of-00001.parquet")) as r:
            cache.write_bytes(r.read())
    t = pq.read_table(cache).to_pylist()
    rows = sorted((x for x in t if x["language"] == "mixed" and MIN_S <= x["duration"] <= MAX_S), key=lambda x: x["id"])
    # spread the picks over the whole split instead of taking one session
    step = max(1, len(rows) // n)
    picked = []
    for x in rows[::step][:n]:
        audio, sr = sf.read(io.BytesIO(x["audio"]["bytes"]), dtype="float32")
        cid = f"mixed-{len(picked) + 1:03d}"
        path, dur = save(out, cid, audio, sr)
        picked.append({"id": cid, "category": "mixed", "audio": path.name, "duration": dur,
                       "text": x["transcription"], "entities": [],
                       "source": f"CAiRE/ASCEND:test/{x['id']}", "license": "CC-BY-SA-4.0"})
    return picked


def context_asr(out, n):
    with open_url(url("MrSupW/ContextASR-Bench", "ContextASR-Speech_Mandarin.jsonl")) as r:
        meta = {}
        for line in io.TextIOWrapper(r, encoding="utf-8"):
            x = json.loads(line)
            if MIN_S <= float(x["duration"]) <= MAX_S and x.get("entity_list"):
                meta[Path(x["audio"]).name] = x
    picked = []
    with open_url(url("MrSupW/ContextASR-Bench", "audio/ContextASR-Speech/Mandarin/ContextASR-Speech_Mandarin_1.tar")) as r:
        with tarfile.open(fileobj=r, mode="r|") as tar:
            for m in tar:
                name = Path(m.name).name
                if not m.isfile() or name not in meta:
                    continue
                x = meta[name]
                audio, sr = sf.read(io.BytesIO(tar.extractfile(m).read()), dtype="float32")
                cid = f"entity-{len(picked) + 1:03d}"
                path, dur = save(out, cid, audio, sr)
                picked.append({"id": cid, "category": "entity", "audio": path.name, "duration": dur,
                               "text": x["text"], "entities": x["entity_list"],
                               "source": f"MrSupW/ContextASR-Bench:Speech/Mandarin/{x['uniq_id']}", "license": "MIT"})
                if len(picked) == n:
                    break
    return picked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    clips = []
    for name, fn in [("zh", lambda: fleurs(out, "cmn_hans_cn", "zh", 40)),
                     ("en", lambda: fleurs(out, "en_us", "en", 30)),
                     ("mixed", lambda: ascend(out, 30)),
                     ("entity", lambda: context_asr(out, 20))]:
        got = fn()
        print(f"{name}: {len(got)} clips, {sum(c['duration'] for c in got):.0f} s", flush=True)
        clips += got
    with open(HERE / "testset.jsonl", "w", encoding="utf-8") as f:
        for c in clips:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    print(f"total {len(clips)} clips -> {HERE / 'testset.jsonl'}")


if __name__ == "__main__":
    main()
