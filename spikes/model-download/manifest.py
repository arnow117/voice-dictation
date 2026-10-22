#!/usr/bin/env python3
"""Build models.json for the downloader spike from the Hugging Face API (FEAT-001 T003).

Each model is pinned to a commit. Large files carry the SHA-256 that Hugging Face
reports for LFS objects; small text files have no LFS hash, so `pin` fills them
in from verified local copies and marks them as computed.

  uv run --no-project --python 3.12 python spikes/model-download/manifest.py build
  uv run --no-project --python 3.12 python spikes/model-download/manifest.py pin --dest <models dir>
"""
import argparse
import fnmatch
import json
import sys
import urllib.request
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from download import sha256_file  # noqa: E402

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "models.json"

# Candidates for T001. Revisions pinned on 2026-10-21; `license` is the upstream model licence.
MODELS = {
    "qwen3-asr-0.6b-int8": {
        "repo": "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
        "revision": "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a",
        "license": "Apache-2.0 (Qwen3-ASR)",
        "files": ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer/*"],
        "extras": ["test_wavs/*"],
    },
    "sensevoice-small-int8": {
        "repo": "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
        "revision": "355f4d4884d8afd08aef04b9007a8556d7b463b2",
        "license": "FunASR model licence (SenseVoice) - to be reviewed before shipping",
        "files": ["model.int8.onnx", "tokens.txt"],
        "extras": [],
    },
    "funasr-nano-int8": {
        "repo": "csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30",
        "revision": "6f16bd378457e13f36ccf3910df9017f96c346fb",
        "license": "Apache-2.0 (Fun-ASR-Nano-2512)",
        "files": ["embedding.int8.onnx", "encoder_adaptor.int8.onnx", "llm.int8.onnx", "Qwen3-0.6B/*"],
        "extras": [],
    },
    "whisper-turbo-int8": {
        "repo": "csukuangfj/sherpa-onnx-whisper-turbo",
        "revision": "2ca6ff69fc878651b770880507669577ac41c2ff",
        "license": "MIT (OpenAI Whisper)",
        "files": ["turbo-encoder.int8.onnx", "turbo-decoder.int8.onnx", "turbo-tokens.txt"],
        "extras": [],
    },
}


def hf_tree(repo, revision):
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "shanshuo-spike/0.1"}), timeout=30) as r:
        return [x for x in json.load(r) if x.get("type") == "file"]


def select(tree, patterns):
    out = []
    for x in tree:
        if any(fnmatch.fnmatch(x["path"], p) for p in patterns):
            lfs = x.get("lfs") or {}
            out.append({"path": x["path"], "size": x["size"], "sha256": lfs.get("oid"),
                        "sha256_source": "huggingface-lfs" if lfs.get("oid") else None})
    return sorted(out, key=lambda e: e["path"])


def build():
    manifest = {"generated": str(date.today()), "note": "FEAT-001 T003 spike; sizes and LFS SHA-256 from the Hugging Face API at the pinned revision",
                "models": {}}
    for key, m in MODELS.items():
        tree = hf_tree(m["repo"], m["revision"])
        files = select(tree, m["files"])
        missing = [p for p in m["files"] if not any(fnmatch.fnmatch(f["path"], p) for f in files)]
        if missing:
            raise SystemExit(f"{key}: patterns matched nothing: {missing}")
        manifest["models"][key] = {"repo": m["repo"], "revision": m["revision"], "license": m["license"],
                                   "total_bytes": sum(f["size"] for f in files),
                                   "files": files, "extras": select(tree, m["extras"])}
        print(f"{key}: {len(files)} files, {manifest['models'][key]['total_bytes'] / 1048576:.1f} MB, "
              f"{sum(1 for f in files if not f['sha256'])} without LFS hash")
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


def pin(dest):
    manifest = json.loads(MANIFEST.read_text())
    for key, m in manifest["models"].items():
        for e in m["files"] + m["extras"]:
            if e["sha256"]:
                continue
            p = Path(dest) / key / e["path"]
            if p.exists() and p.stat().st_size == e["size"]:
                e["sha256"] = sha256_file(p)
                e["sha256_source"] = f"computed-{date.today()}"
                print(f"pinned {key}/{e['path']}")
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build")
    p = sub.add_parser("pin")
    p.add_argument("--dest", required=True)
    a = ap.parse_args()
    build() if a.cmd == "build" else pin(a.dest)
