#!/usr/bin/env python3
"""Resumable, verified model downloader spike (FEAT-001 T003).

Validates the ED-009 download behaviour before it is rewritten in Swift (T012):
per-file HTTP Range resume, fallback to the next source, resuming a partial file
from a different source, SHA-256 verification with one automatic re-download,
and atomic rename so a half-written file is never mistaken for a finished one.

Usage:
  uv run --no-project --python 3.12 python spikes/model-download/download.py \
      --manifest spikes/model-download/models.json --model qwen3-asr-0.6b-int8 \
      --dest <dir> [--source hf --source hf-mirror] [--interrupt-after BYTES]
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CHUNK = 1 << 20
USER_AGENT = "shanshuo-spike/0.1"
SOURCES = {
    "hf": "https://huggingface.co/{repo}/resolve/{revision}/{path}",
    "hf-mirror": "https://hf-mirror.com/{repo}/resolve/{revision}/{path}",
}
NETWORK_ERRORS = (urllib.error.URLError, TimeoutError, ConnectionError, OSError)


class DownloadError(Exception):
    """The file could not be obtained with a matching size and checksum."""


class Interrupted(Exception):
    """Raised by --interrupt-after to simulate a dropped connection."""


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for buf in iter(lambda: f.read(CHUNK), b""):
            h.update(buf)
    return h.hexdigest()


def _fetch(url, part, expected_size, interrupt_after=None, timeout=30):
    """Append the missing bytes of `url` to `part`.

    Returns "fresh", "resumed" (server honoured Range) or "restarted"
    (server ignored Range, so the partial file was discarded).
    """
    offset = part.stat().st_size if part.exists() else 0
    if offset > expected_size:
        part.unlink()
        offset = 0
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if offset:
        req.add_header("Range", f"bytes={offset}-")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if offset and resp.status == 206:
            start = int(resp.headers.get("Content-Range", "bytes 0-").split()[1].split("-")[0])
            if start != offset:
                raise DownloadError(f"server resumed at {start}, expected {offset}")
            how, mode = "resumed", "ab"
        elif offset:
            how, mode = "restarted", "wb"
        else:
            how, mode = "fresh", "wb"
        written = 0
        with open(part, mode) as f:
            while True:
                buf = resp.read(CHUNK)
                if not buf:
                    break
                f.write(buf)
                written += len(buf)
                if interrupt_after is not None and written >= interrupt_after:
                    raise Interrupted(f"simulated interruption after {written} bytes")
    return how


def download_file(entry, dest, sources, interrupt_after=None, log=lambda event: None):
    """Download one manifest entry into `dest`.

    `sources` is an ordered list of (name, url_for_path) pairs. A network error
    moves on to the next source and keeps the partial file, so the next source
    resumes it. A checksum mismatch deletes the partial file and downloads once more.
    """
    target = Path(dest) / entry["path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    expected_sha = entry.get("sha256")

    if target.exists() and target.stat().st_size == entry["size"]:
        if expected_sha is None or sha256_file(target) == expected_sha:
            return {"path": entry["path"], "how": "cached", "source": None,
                    "sha256": expected_sha or sha256_file(target), "sha256_verified": expected_sha is not None,
                    "checksum_retries": 0, "seconds": 0.0, "bytes": 0}

    checksum_retries = 0
    for attempt in range(2):
        started = time.monotonic()
        before = part.stat().st_size if part.exists() else 0
        errors = []
        for name, url_for in sources:
            try:
                how = _fetch(url_for(entry["path"]), part, entry["size"], interrupt_after)
                source = name
                break
            except Interrupted:
                raise
            except NETWORK_ERRORS as exc:
                errors.append(f"{name}: {exc}")
                log({"event": "source_failed", "path": entry["path"], "source": name, "error": str(exc)})
        else:
            raise DownloadError(f"all sources failed for {entry['path']}: {errors}")
        size = part.stat().st_size
        digest = sha256_file(part)
        if size != entry["size"] or (expected_sha is not None and digest != expected_sha):
            part.unlink()
            checksum_retries += 1
            log({"event": "checksum_mismatch", "path": entry["path"], "source": source, "size": size})
            continue
        os.replace(part, target)
        seconds = time.monotonic() - started
        result = {"path": entry["path"], "how": how, "source": source, "sha256": digest,
                  "sha256_verified": expected_sha is not None, "checksum_retries": checksum_retries,
                  "seconds": round(seconds, 2), "bytes": size - (before if how == "resumed" else 0)}
        log({"event": "file_done", **result})
        return result
    raise DownloadError(f"checksum mismatch twice for {entry['path']}")


def source_urls(model, names):
    out = []
    for name in names:
        template = SOURCES[name]
        out.append((name, lambda path, t=template: t.format(repo=model["repo"], revision=model["revision"], path=path)))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--source", action="append", choices=sorted(SOURCES), help="repeatable; tried in order")
    ap.add_argument("--extras", action="store_true", help="also download bench-only extras (test wavs)")
    ap.add_argument("--only", help="download a single file path from the manifest")
    ap.add_argument("--interrupt-after", type=int, help="simulate a dropped connection after N bytes")
    args = ap.parse_args(argv)

    manifest = json.loads(Path(args.manifest).read_text())
    model = manifest["models"][args.model]
    entries = list(model["files"]) + (list(model.get("extras", [])) if args.extras else [])
    if args.only:
        entries = [e for e in entries if e["path"] == args.only]
    dest = Path(args.dest) / args.model
    sources = source_urls(model, args.source or ["hf", "hf-mirror"])

    def log(event):
        print(json.dumps(event, ensure_ascii=False), flush=True)

    total_started = time.monotonic()
    results = []
    for e in entries:
        try:
            results.append(download_file(e, dest, sources, args.interrupt_after, log))
        except Interrupted as exc:
            log({"event": "interrupted", "path": e["path"], "detail": str(exc)})
            return 3
    seconds = time.monotonic() - total_started
    fetched = sum(r["bytes"] for r in results)
    log({"event": "model_done", "model": args.model, "files": len(results), "bytes": fetched,
         "seconds": round(seconds, 1), "mb_per_s": round(fetched / 1048576 / seconds, 1) if seconds else None,
         "unverified": [r["path"] for r in results if not r["sha256_verified"]]})
    return 0


if __name__ == "__main__":
    sys.exit(main())
