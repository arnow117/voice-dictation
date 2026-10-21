#!/usr/bin/env python3
"""T001 local ASR benchmark runner (FEAT-001).

Every configuration runs in its own process so load time and memory are isolated.
Models stay loaded and are warmed up once before timing, matching ED-002 (the app
keeps the recogniser resident). Timing covers create_stream -> result, i.e. the
recognition part of "release key -> text inserted".

  uv run --project bench/asr python bench/asr/run_bench.py make-latency --data <data dir>
  uv run --project bench/asr python bench/asr/run_bench.py all --models <models dir> --data <data dir> --results bench/asr/results
  uv run --project bench/asr python bench/asr/run_bench.py worker --model qwen3-asr-0.6b-int8 --task accuracy ...
"""
import argparse
import json
import os
import random
import resource
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).resolve().parent
MODELS = ["qwen3-asr-0.6b-int8", "sensevoice-small-int8", "funasr-nano-int8", "whisper-turbo-int8"]
HOTWORD_MODELS = {"qwen3-asr-0.6b-int8", "funasr-nano-int8"}
LATENCY_TARGETS = (5, 15, 30)


# ---------------------------------------------------------------- data helpers
def load_testset():
    return [json.loads(l) for l in (HERE / "testset.jsonl").read_text(encoding="utf-8").splitlines() if l]


def read_wav(path):
    audio, sr = sf.read(path, dtype="float32")
    assert sr == 16000, path
    return audio


def make_latency(data_dir):
    """Concatenate test clips (0.25 s gaps) into 10 clips each of 5/15/30 s: 4 zh, 3 en, 3 mixed."""
    clips = load_testset()
    by_cat = {c: [x for x in clips if x["category"] == c] for c in ("zh", "en", "mixed")}
    gap = np.zeros(4000, dtype=np.float32)
    out_dir = Path(data_dir) / "latency"
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for target in LATENCY_TARGETS:
        for i in range(10):
            cat = "zh" if i < 4 else ("en" if i < 7 else "mixed")
            pool = by_cat[cat]
            parts, total, k = [], 0, i * 3
            while total < target * 16000:
                a = read_wav(Path(data_dir) / "clips" / pool[k % len(pool)]["audio"])
                parts += [a, gap]
                total += len(a) + len(gap)
                k += 1
            audio = np.concatenate(parts)[: target * 16000]
            name = f"lat-{target:02d}s-{i:02d}.wav"
            sf.write(out_dir / name, audio, 16000, subtype="PCM_16")
            rows.append({"id": name[:-4], "target_s": target, "category": cat, "audio": name})
    (Path(data_dir) / "latency.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    print(f"{len(rows)} latency clips -> {out_dir}")


def hotword_lists(entity_clips, distractors):
    """Return {mode: (list or None for per-clip/per-dialogue)} for the hotword experiment."""
    base = sorted({e for c in entity_clips for e in c["entities"]})
    pool = [d for d in distractors if d not in set(base)]
    lists = {}
    for n in (50, 100, 200):
        words = base + pool[: max(0, n - len(base))]
        random.Random(n).shuffle(words)
        lists[f"global-{n}"] = words
    return base, lists


# ---------------------------------------------------------------- recogniser
def build(key, d, threads, provider, hotwords=""):
    import sherpa_onnx as so
    d = Path(d)
    if key == "qwen3-asr-0.6b-int8":
        return so.OfflineRecognizer.from_qwen3_asr(
            conv_frontend=str(d / "conv_frontend.onnx"), encoder=str(d / "encoder.int8.onnx"),
            decoder=str(d / "decoder.int8.onnx"), tokenizer=str(d / "tokenizer"), num_threads=threads,
            provider=provider, max_total_len=2048, max_new_tokens=256, hotwords=hotwords)
    if key == "funasr-nano-int8":
        return so.OfflineRecognizer.from_funasr_nano(
            encoder_adaptor=str(d / "encoder_adaptor.int8.onnx"), llm=str(d / "llm.int8.onnx"),
            embedding=str(d / "embedding.int8.onnx"), tokenizer=str(d / "Qwen3-0.6B"), num_threads=threads,
            provider=provider, max_new_tokens=512, itn=True, hotwords=hotwords)
    if key == "whisper-turbo-int8":
        return so.OfflineRecognizer.from_whisper(
            encoder=str(d / "turbo-encoder.int8.onnx"), decoder=str(d / "turbo-decoder.int8.onnx"),
            tokens=str(d / "turbo-tokens.txt"), num_threads=threads, provider=provider, language="", task="transcribe")
    if key == "sensevoice-small-int8":
        return so.OfflineRecognizer.from_sense_voice(
            model=str(d / "model.int8.onnx"), tokens=str(d / "tokens.txt"), num_threads=threads,
            provider=provider, language="auto", use_itn=True)
    raise SystemExit(f"unknown model {key}")


def rss_mb():
    import psutil
    return round(psutil.Process().memory_info().rss / 1048576, 1)


def peak_mb():
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576, 1)  # bytes on macOS


def decode(rec, audio, options=None):
    t = time.perf_counter()
    s = rec.create_stream()
    for k, v in (options or {}).items():
        s.set_option(k, v)
    s.accept_waveform(16000, audio)
    rec.decode_stream(s)
    return s.result.text, time.perf_counter() - t


def foreground_qos():
    """Schedule like the app's recognition task (user-initiated work on performance cores).

    Background jobs on macOS can be put in the Darwin background band, which confines them
    to efficiency cores; on 2026-10-21 that made Qwen3-ASR 2-3x slower. Clear that state and
    raise this thread to QOS_CLASS_USER_INTERACTIVE before onnxruntime creates its threads.
    """
    import ctypes
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    PRIO_DARWIN_PROCESS, QOS_USER_INTERACTIVE = 4, 0x21
    info = {"darwin_bg_before": libc.getpriority(PRIO_DARWIN_PROCESS, 0)}
    info["clear_bg_rc"] = libc.setpriority(PRIO_DARWIN_PROCESS, 0, 0)
    info["darwin_bg_after"] = libc.getpriority(PRIO_DARWIN_PROCESS, 0)
    info["set_qos_rc"] = libc.pthread_set_qos_class_self_np(QOS_USER_INTERACTIVE, 0)
    libc.pthread_self.restype = ctypes.c_void_p
    libc.pthread_get_qos_class_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_int)]
    qos, rel = ctypes.c_uint(), ctypes.c_int()
    libc.pthread_get_qos_class_np(libc.pthread_self(), ctypes.byref(qos), ctypes.byref(rel))
    info["qos_now"] = hex(qos.value)
    return info


# ---------------------------------------------------------------- worker
def worker(a):
    qos = foreground_qos()
    out = open(a.out, "w", encoding="utf-8")

    def emit(row):
        out.write(json.dumps(row, ensure_ascii=False) + "\n")
        out.flush()

    data = Path(a.data)
    meta = {"type": "meta", "model": a.model, "task": a.task, "threads": a.threads, "provider": a.provider,
            "hotwords_mode": a.hotwords_mode, "rss_before_mb": rss_mb(), "qos": qos}
    clips = load_testset()
    if a.task == "latency":
        items = [dict(r, path=str(data / "latency" / r["audio"])) for r in
                 (json.loads(l) for l in (data / "latency.jsonl").read_text().splitlines() if l)]
    else:
        items = [dict(c, path=str(data / "clips" / c["audio"])) for c in clips
                 if a.task == "accuracy" or c["category"] == "entity"]
    if a.limit:
        items = items[: a.limit]

    words_for = lambda item: ""  # noqa: E731
    static = ""
    if a.task == "hotwords" and a.hotwords_mode != "none":
        distractors = [l.strip() for l in (HERE / "hotword_distractors.txt").read_text(encoding="utf-8").splitlines() if l.strip()]
        entity_clips = [c for c in clips if c["category"] == "entity"]
        base, lists = hotword_lists(entity_clips, distractors)
        meta["hotword_base"] = len(base)
        if a.hotwords_mode == "clip":
            words_for = lambda item: ",".join(item["entities"])  # noqa: E731
        elif a.hotwords_mode == "dialogue":
            words_for = lambda item: ",".join(item["dialogue_entities"])  # noqa: E731
        else:
            static = ",".join(lists[a.hotwords_mode])
            words_for = lambda item: static  # noqa: E731
        meta["hotword_count_example"] = len(words_for(items[0]).split(","))

    per_stream = a.model == "qwen3-asr-0.6b-int8"  # Qwen3-ASR reads SetOption("hotwords"); Fun-ASR-Nano only the config
    t = time.perf_counter()
    rec = build(a.model, Path(a.models) / a.model, a.threads, a.provider, "" if per_stream else static)
    meta["load_s"] = round(time.perf_counter() - t, 3)
    meta["rss_after_load_mb"] = rss_mb()
    warm = read_wav(items[0]["path"])
    _, meta["warmup_s"] = decode(rec, warm)
    meta["rss_after_warmup_mb"] = rss_mb()
    emit(meta)

    import threading
    import psutil
    samples, stop = [], threading.Event()

    def sample():
        psutil.cpu_percent(percpu=True)
        while not stop.wait(1.0):
            samples.append(psutil.cpu_percent(percpu=True))
    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()

    current_words = static
    for item in items:
        audio = read_wav(item["path"])
        words = words_for(item)
        opts = {}
        if per_stream and words:
            opts["hotwords"] = words
        rebuild_s = None
        if not per_stream and a.task == "hotwords" and words != current_words:
            t = time.perf_counter()
            rec = build(a.model, Path(a.models) / a.model, a.threads, a.provider, words)
            rebuild_s = round(time.perf_counter() - t, 3)
            current_words = words
        try:
            text, secs = decode(rec, audio, opts)
            err = None
        except Exception as exc:  # keep going; the report counts failures
            text, secs, err = "", None, repr(exc)
        emit({"type": "clip", "id": item["id"], "category": item["category"], "duration": round(len(audio) / 16000, 3),
              "target_s": item.get("target_s"), "hyp": text, "decode_s": None if secs is None else round(secs, 4),
              "rebuild_s": rebuild_s, "hotword_count": len(words.split(",")) if words else 0, "error": err})
    stop.set()
    sampler.join()
    avg = [round(sum(col) / len(col), 1) for col in zip(*samples)] if samples else []
    emit({"type": "end", "rss_end_mb": rss_mb(), "peak_rss_mb": peak_mb(), "cpu_percpu_avg": avg})
    out.close()


# ---------------------------------------------------------------- orchestration
def plan(suite="full"):
    """agent: what can be measured inside the agent sandbox (accuracy and hotword recall do not depend on
    which cores run the model). terminal: timing runs, executed by the user in their own Terminal because the
    agent's process tree is confined to efficiency cores (see README)."""
    def r(model, task, threads=4, provider="cpu", mode="none"):
        return dict(model=model, task=task, threads=threads, provider=provider, hotwords_mode=mode)
    acc = [r(m, "accuracy") for m in MODELS]
    lat4 = [r(m, "latency") for m in MODELS]
    threads = [r("qwen3-asr-0.6b-int8", "latency", th) for th in (2, 6, 8)]
    coreml = [r(m, "latency", 4, "coreml") for m in ("qwen3-asr-0.6b-int8", "sensevoice-small-int8")]
    hot = [r("qwen3-asr-0.6b-int8", "hotwords", mode=x) for x in ("none", "clip", "dialogue", "global-50", "global-100", "global-200")]
    hot += [r("funasr-nano-int8", "hotwords", mode=x) for x in ("none", "dialogue", "global-100")]
    if suite == "agent":  # whisper is slowest on CPU, run it last
        return acc[:3] + [lat4[0]] + hot + [acc[3]]
    if suite == "terminal":
        return lat4 + threads + coreml
    return acc + lat4 + threads + coreml + hot


def run_name(r):
    return f"{r['model']}__{r['task']}__t{r['threads']}__{r['provider']}__{r['hotwords_mode']}"


def run_all(a):
    res = Path(a.results)
    res.mkdir(parents=True, exist_ok=True)
    lock = Path(a.lock) if a.lock else None
    if lock:
        lock.write_text(str(os.getpid()))
    try:
        _run_all(a, res)
    finally:
        if lock and lock.exists():
            lock.unlink()


def _run_all(a, res):
    runs = plan(a.suite)
    if a.filter:
        runs = [r for r in runs if a.filter in run_name(r)]
    for i, r in enumerate(runs, 1):
        name = run_name(r)
        out = res / f"{name}.jsonl"
        if out.exists() and not a.force and '"type": "end"' in out.read_text(encoding="utf-8"):
            print(f"[{i}/{len(runs)}] skip {name} (done)", flush=True)
            continue
        cmd = [sys.executable, __file__, "worker", "--models", a.models, "--data", a.data, "--out", str(out),
               "--model", r["model"], "--task", r["task"], "--threads", str(r["threads"]),
               "--provider", r["provider"], "--hotwords-mode", r["hotwords_mode"]]
        t = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True, text=True)
        status = "ok" if p.returncode == 0 else f"exit {p.returncode}"
        (res / f"{name}.log").write_text(p.stdout + p.stderr)
        print(f"[{i}/{len(runs)}] {name}: {status} in {time.perf_counter() - t:.0f}s", flush=True)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("make-latency")
    p.add_argument("--data", required=True)
    p = sub.add_parser("all")
    p.add_argument("--models", required=True)
    p.add_argument("--data", required=True)
    p.add_argument("--results", required=True)
    p.add_argument("--filter")
    p.add_argument("--force", action="store_true")
    p.add_argument("--suite", choices=["full", "agent", "terminal"], default="full")
    p.add_argument("--lock", help="file that exists while this run is active (terminal suite waits for it)")
    p = sub.add_parser("worker")
    for k in ("--models", "--data", "--out", "--model", "--task"):
        p.add_argument(k, required=True)
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("--provider", default="cpu")
    p.add_argument("--hotwords-mode", default="none")
    p.add_argument("--limit", type=int, help="smoke test: only the first N items")
    a = ap.parse_args()
    {"make-latency": lambda: make_latency(a.data), "all": lambda: run_all(a), "worker": lambda: worker(a)}[a.cmd]()


if __name__ == "__main__":
    main()
