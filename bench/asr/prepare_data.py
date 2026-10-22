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
| entity   | 20 | ContextASR-Bench Dialogue zh turns  | MIT          |

  uv run --project bench/asr python bench/asr/prepare_data.py --out <dir>
"""
import argparse
import ast
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


def _entity_list(value):
    if isinstance(value, list):
        return value
    return list(ast.literal_eval(value)) if value else []


def _compact(text):
    return "".join(text.split()).lower()


def context_asr(out, n, per_dialogue=3):
    """Cut 3-20 s turns that mention at least one entity from ContextASR-Dialogue (Mandarin).

    ContextASR-Speech clips are 24-97 s monologues (median 45 s), far from dictation,
    so single dialogue turns with start/end timestamps are used instead.
    """
    with open_url(url("MrSupW/ContextASR-Bench", "ContextASR-Dialogue_Mandarin.jsonl")) as r:
        meta = {}
        for line in io.TextIOWrapper(r, encoding="utf-8"):
            x = json.loads(line)
            meta[Path(x["audio"]).name] = x
    picked = []
    tar_url = url("MrSupW/ContextASR-Bench", "audio/ContextASR-Dialogue/Mandarin/ContextASR-Dialogue_Mandarin_1.tar")
    with open_url(tar_url) as r:
        with tarfile.open(fileobj=r, mode="r|") as tar:
            for m in tar:
                name = Path(m.name).name
                if not m.isfile() or name not in meta:
                    continue
                x = meta[name]
                entities = _entity_list(x["entity_list"])
                audio, sr = sf.read(io.BytesIO(tar.extractfile(m).read()), dtype="float32")
                taken = 0
                for turn_no, turn in enumerate(x["dialogue"]):
                    dur = float(turn["end"]) - float(turn["start"])
                    mentioned = [e for e in entities if _compact(e) and _compact(e) in _compact(turn["text"])]
                    if not (MIN_S <= dur <= MAX_S) or not mentioned:
                        continue
                    seg = audio[int(float(turn["start"]) * sr):int(float(turn["end"]) * sr)]
                    cid = f"entity-{len(picked) + 1:03d}"
                    path, d = save(out, cid, seg, sr)
                    picked.append({"id": cid, "category": "entity", "audio": path.name, "duration": d,
                                   "text": turn["text"], "entities": mentioned, "dialogue_entities": entities,
                                   "source": f"MrSupW/ContextASR-Bench:Dialogue/Mandarin/{x['uniq_id']}#turn{turn_no}",
                                   "license": "MIT"})
                    taken += 1
                    if taken == per_dialogue or len(picked) == n:
                        break
                if len(picked) == n:
                    break
    return picked


def distractors(n=400):
    """Hotword distractors: entities from ContextASR-Speech (Mandarin), a different subset from the test turns."""
    seen, out = set(), []
    with open_url(url("MrSupW/ContextASR-Bench", "ContextASR-Speech_Mandarin.jsonl")) as r:
        for line in io.TextIOWrapper(r, encoding="utf-8"):
            for e in _entity_list(json.loads(line)["entity_list"]):
                e = e.strip()
                if 2 <= len(e) <= 8 and " " not in e and e not in seen:
                    seen.add(e)
                    out.append(e)
            if len(out) >= n:
                break
    (HERE / "hotword_distractors.txt").write_text("\n".join(out[:n]) + "\n", encoding="utf-8")
    print(f"{len(out[:n])} distractors -> {HERE / 'hotword_distractors.txt'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", choices=["zh", "en", "mixed", "entity"], help="rebuild one category, keep the others")
    ap.add_argument("--distractors", action="store_true", help="only (re)write hotword_distractors.txt")
    a = ap.parse_args()
    if a.distractors:
        return distractors()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    builders = {"zh": lambda: fleurs(out, "cmn_hans_cn", "zh", 40),
                "en": lambda: fleurs(out, "en_us", "en", 30),
                "mixed": lambda: ascend(out, 30),
                "entity": lambda: context_asr(out, 20)}
    manifest = HERE / "testset.jsonl"
    clips = []
    if a.only and manifest.exists():
        clips = [c for c in (json.loads(l) for l in manifest.read_text(encoding="utf-8").splitlines() if l)
                 if c["category"] != a.only]
    for name in ([a.only] if a.only else builders):
        got = builders[name]()
        print(f"{name}: {len(got)} clips, {sum(c['duration'] for c in got):.0f} s", flush=True)
        clips += got
    order = {"zh": 0, "en": 1, "mixed": 2, "entity": 3}
    clips.sort(key=lambda c: (order[c["category"]], c["id"]))
    with open(manifest, "w", encoding="utf-8") as f:
        for c in clips:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    print(f"total {len(clips)} clips -> {manifest}")


if __name__ == "__main__":
    main()
