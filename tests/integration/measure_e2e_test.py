#!/usr/bin/env python3
"""Exercise the fixture-player boundary without playing audio or opening the application."""

from __future__ import annotations

import json
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MEASURE = ROOT / "bench/e2e/measure.py"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def write_first_buffer_event(directory: Path, process_id: str) -> None:
    event = {
        "schema_version": 1,
        "kind": "audio_first_buffer",
        "result": "observed",
        "process_id": process_id,
        "session_id": str(uuid.uuid4()),
        "monotonic_ns": 105_890_169_407_458,
        "audio_duration_ns": None,
    }
    (directory / "performance-fixture.jsonl").write_text(
        json.dumps(event) + "\n", encoding="utf-8"
    )


def wait_for_requested_report(report_path: Path) -> dict[str, object]:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if report_path.exists():
            report = json.loads(report_path.read_text(encoding="utf-8"))
            if report.get("playback_status") == "requested":
                return report
        time.sleep(0.02)
    raise AssertionError("measurement never wrote the requested player receipt")


def make_player(directory: Path, name: str, script: str) -> Path:
    player = directory / name
    player.write_text("#!/bin/sh\n" + script + "\n", encoding="utf-8")
    player.chmod(0o755)
    return player


def run_measurement(
    directory: Path,
    player: Path,
    report_path: Path,
    process_id: str,
) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [
            "python3",
            str(MEASURE),
            "play-fixture-after-first-buffer",
            "--diagnostics-dir",
            str(directory),
            "--audio",
            str(directory / "fixture.wav"),
            "--output",
            str(report_path),
            "--process-id",
            process_id,
            "--player",
            str(player),
            "--timeout-seconds",
            "2",
            "--playback-timeout-seconds",
            "2",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_success_waits_for_player(directory: Path) -> None:
    process_id = str(uuid.uuid4())
    report_path = directory / "success.json"
    player = make_player(directory, "success-player", "sleep 0.2\nexit 0")
    command = run_measurement(directory, player, report_path, process_id)
    time.sleep(0.1)
    write_first_buffer_event(directory, process_id)

    requested = wait_for_requested_report(report_path)
    check(
        requested["first_buffer_clock"] == "app_mach_absolute_time_nanoseconds",
        "the receipt identifies the app first-buffer clock domain",
    )
    check(
        requested["playback_request_clock"] == "python_time_monotonic_ns",
        "the receipt identifies the Python request clock domain",
    )
    check(
        "latency_ns" not in requested,
        "the receipt does not subtract timestamps from separate clock epochs",
    )

    stdout, stderr = command.communicate(timeout=3)
    check(command.returncode == 0, f"zero-exit player failed: {stdout}\n{stderr}")
    completed = json.loads(report_path.read_text(encoding="utf-8"))
    check(completed["playback_status"] == "completed", "zero-exit player completes the receipt")
    check(completed["playback_exit_code"] == 0, "zero-exit player is recorded")
    check(
        completed["playback_completed_clock"] == "python_time_monotonic_ns",
        "completion time retains its Python clock domain",
    )


def test_nonzero_player_fails_measurement(directory: Path) -> None:
    process_id = str(uuid.uuid4())
    report_path = directory / "failure.json"
    player = make_player(directory, "failure-player", "exit 7")
    command = run_measurement(directory, player, report_path, process_id)
    time.sleep(0.1)
    write_first_buffer_event(directory, process_id)

    stdout, stderr = command.communicate(timeout=3)
    check(command.returncode == 2, f"nonzero player did not fail: {stdout}\n{stderr}")
    failed = json.loads(report_path.read_text(encoding="utf-8"))
    check(failed["playback_status"] == "failed", "nonzero player marks playback failed")
    check(failed["playback_exit_code"] == 7, "the player exit code is recorded")


def test_missing_player_fails_measurement(directory: Path) -> None:
    process_id = str(uuid.uuid4())
    report_path = directory / "missing-player.json"
    command = run_measurement(directory, directory / "missing-player", report_path, process_id)
    time.sleep(0.1)
    write_first_buffer_event(directory, process_id)

    stdout, stderr = command.communicate(timeout=3)
    check(command.returncode == 2, f"missing player did not fail: {stdout}\n{stderr}")
    failed = json.loads(report_path.read_text(encoding="utf-8"))
    check(failed["playback_status"] == "request_failed", "failed launch is distinct from completion")
    check(
        failed["playback_error_kind"] == "FileNotFoundError",
        "failed launch records only its fixed error class",
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="shanshuo-measure-e2e-") as temporary_directory:
        directory = Path(temporary_directory)
        (directory / "fixture.wav").touch()
        test_success_waits_for_player(directory)
        for path in directory.glob("performance-*.jsonl"):
            path.unlink()
        test_nonzero_player_fails_measurement(directory)
        for path in directory.glob("performance-*.jsonl"):
            path.unlink()
        test_missing_player_fails_measurement(directory)
    print("measure e2e test passed")


if __name__ == "__main__":
    main()
