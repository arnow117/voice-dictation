#!/usr/bin/env python3
"""Read-only helpers for a real Shanshuo performance run."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def parse_cpu_seconds(value: str) -> float:
    """Parse the cumulative CPU time format emitted by macOS ps."""
    parts = value.strip().split(":")
    if not parts or not all(part for part in parts):
        raise ValueError(f"unsupported CPU time: {value!r}")

    seconds = float(parts[-1])
    multiplier = 60.0
    for part in reversed(parts[:-1]):
        seconds += int(part) * multiplier
        multiplier *= 60.0
    return seconds


def read_process_snapshot(pid: int) -> dict[str, Any]:
    command = ["ps", "-p", str(pid), "-o", "pid=", "-o", "lstart=", "-o", "utime=", "-o", "stime="]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    fields = completed.stdout.split()
    if len(fields) != 8:
        raise RuntimeError(f"unable to read a complete ps snapshot for PID {pid}: {completed.stdout!r}")

    observed_pid = int(fields[0])
    if observed_pid != pid:
        raise RuntimeError(f"PID changed while sampling: expected {pid}, observed {observed_pid}")

    return {
        "pid": observed_pid,
        "lstart": " ".join(fields[1:6]),
        "user_seconds": parse_cpu_seconds(fields[6]),
        "system_seconds": parse_cpu_seconds(fields[7]),
    }


def measure_cpu(args: argparse.Namespace) -> int:
    first = read_process_snapshot(args.pid)
    first_wall_ns = time.monotonic_ns()
    time.sleep(args.seconds)
    second = read_process_snapshot(args.pid)
    second_wall_ns = time.monotonic_ns()

    if second["lstart"] != first["lstart"]:
        raise RuntimeError("PID identity changed while sampling; refusing to report CPU")

    wall_seconds = (second_wall_ns - first_wall_ns) / 1_000_000_000
    if wall_seconds <= 0:
        raise RuntimeError("monotonic wall duration was not positive")

    first_cpu = first["user_seconds"] + first["system_seconds"]
    second_cpu = second["user_seconds"] + second["system_seconds"]
    if second_cpu < first_cpu:
        raise RuntimeError("cumulative CPU time moved backwards; refusing to report CPU")

    report = {
        "kind": "idle_cpu",
        "method": "two_endpoint_ps_user_plus_system_over_monotonic_wall",
        "pid": args.pid,
        "process_lstart": first["lstart"],
        "requested_wall_seconds": args.seconds,
        "measured_wall_seconds": wall_seconds,
        "user_cpu_seconds": second["user_seconds"] - first["user_seconds"],
        "system_cpu_seconds": second["system_seconds"] - first["system_seconds"],
        "cpu_percent_one_core": (second_cpu - first_cpu) / wall_seconds * 100,
    }
    write_json(args.output, report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


def read_event_lines(directory: Path) -> list[tuple[Path, int, dict[str, Any]]]:
    events: list[tuple[Path, int, dict[str, Any]]] = []
    for path in sorted(directory.glob("performance-*.jsonl")):
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
            if not line:
                continue
            try:
                events.append((path, index, json.loads(line)))
            except json.JSONDecodeError:
                continue
    return events


def measure_playback_latency(args: argparse.Namespace) -> int:
    fixture = args.audio.resolve()
    if not fixture.is_file() or fixture.suffix.lower() != ".wav":
        raise RuntimeError(f"expected an existing WAV fixture: {fixture}")
    diagnostics_directory = args.diagnostics_dir.resolve()
    if not diagnostics_directory.is_dir():
        raise RuntimeError(f"diagnostics directory does not exist: {diagnostics_directory}")

    existing_lines = {(path, line_index) for path, line_index, _ in read_event_lines(diagnostics_directory)}
    deadline = time.monotonic() + args.timeout_seconds
    while time.monotonic() < deadline:
        for path, line_index, event in read_event_lines(diagnostics_directory):
            if (path, line_index) in existing_lines:
                continue
            if event.get("kind") != "audio_first_buffer" or event.get("result") != "observed":
                continue
            if args.process_id and event.get("process_id") != args.process_id:
                continue

            requested_at_ns = time.monotonic_ns()
            subprocess.Popen(["afplay", str(fixture)])
            report = {
                "kind": "fixture_playback_requested",
                "trigger": "production_audio_first_buffer",
                "diagnostic_process_id": event.get("process_id"),
                "diagnostic_session_id": event.get("session_id"),
                "first_buffer_monotonic_ns": event.get("monotonic_ns"),
                "playback_request_monotonic_ns": requested_at_ns,
                "fixture": str(fixture),
            }
            write_json(args.output, report)
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 0
        time.sleep(0.05)

    raise TimeoutError("no new production audio_first_buffer event arrived before the timeout")


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)

    cpu = subcommands.add_parser("cpu", help="measure one process with exactly two ps snapshots")
    cpu.add_argument("--pid", type=int, required=True)
    cpu.add_argument("--seconds", type=float, default=120)
    cpu.add_argument("--output", type=Path, required=True)
    cpu.set_defaults(run=measure_cpu)

    latency = subcommands.add_parser(
        "play-fixture-after-first-buffer",
        help="play a WAV fixture only after a new production first-buffer event",
    )
    latency.add_argument("--diagnostics-dir", type=Path, required=True)
    latency.add_argument("--audio", type=Path, required=True)
    latency.add_argument("--output", type=Path, required=True)
    latency.add_argument("--process-id")
    latency.add_argument("--timeout-seconds", type=float, default=30)
    latency.set_defaults(run=measure_playback_latency)

    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        return arguments.run(arguments)
    except (OSError, RuntimeError, TimeoutError, ValueError, subprocess.SubprocessError) as error:
        print(f"measurement failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
