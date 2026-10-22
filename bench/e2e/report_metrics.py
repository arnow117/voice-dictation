#!/usr/bin/env python3
"""Summarize closed Shanshuo performance events without treating failed samples as passes."""

from __future__ import annotations

import argparse
import json
import math
import sys
import uuid
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable


EVENT_KINDS = {
    "process_started",
    "cold_start_ready",
    "hotkey_pressed",
    "hotkey_released",
    "recording_display_committed",
    "audio_engine_started",
    "audio_first_buffer",
    "audio_stopped",
    "recognition_delivered",
    "ax_readback_verified",
    "copy_completed",
    "paste_requested",
    "unicode_requested",
    "session_finished",
}
EVENT_RESULTS = {
    "observed",
    "ready",
    "succeeded",
    "failed",
    "cancelled",
    "delivered",
    "verified_insertion",
    "copied",
    "unverified",
    "requested",
}
EVENT_KEYS = {
    "schema_version",
    "kind",
    "result",
    "process_id",
    "session_id",
    "monotonic_ns",
    "audio_duration_ns",
}


def read_events(directory: Path) -> tuple[list[dict[str, Any]], list[str]]:
    events: list[dict[str, Any]] = []
    invalid_lines: list[str] = []
    for path in sorted(directory.glob("performance-*.jsonl")):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if not line:
                continue
            try:
                event = json.loads(line)
                validate_event(event)
            except (json.JSONDecodeError, ValueError, TypeError) as error:
                invalid_lines.append(f"{path.name}:{line_number}: {error}")
                continue
            events.append(event)
    return events, invalid_lines


def validate_event(event: dict[str, Any]) -> None:
    if not isinstance(event, dict) or set(event) != EVENT_KEYS:
        raise ValueError("event schema keys do not match the closed diagnostics schema")
    if event["schema_version"] != 1:
        raise ValueError("unsupported schema version")
    if event["kind"] not in EVENT_KINDS or event["result"] not in EVENT_RESULTS:
        raise ValueError("unknown event kind or result")
    uuid.UUID(event["process_id"])
    uuid.UUID(event["session_id"])
    if not isinstance(event["monotonic_ns"], int) or event["monotonic_ns"] < 0:
        raise ValueError("invalid monotonic timestamp")
    if event["audio_duration_ns"] is not None and (
        not isinstance(event["audio_duration_ns"], int) or event["audio_duration_ns"] < 0
    ):
        raise ValueError("invalid audio duration")


def percentile(values: list[float], percentage: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentage / 100
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def milliseconds(value_ns: int) -> float:
    return value_ns / 1_000_000


def uuid_argument(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a UUID") from error


def grouped_sessions(events: list[dict[str, Any]]) -> dict[tuple[str, str], list[dict[str, Any]]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        groups[(event["process_id"], event["session_id"])].append(event)
    for group in groups.values():
        group.sort(key=lambda event: event["monotonic_ns"])
    return groups


def first_event(
    events: list[dict[str, Any]], kind: str, result: str | None = None
) -> dict[str, Any] | None:
    return next(
        (
            event
            for event in events
            if event["kind"] == kind and (result is None or event["result"] == result)
        ),
        None,
    )


def metric(
    *,
    name: str,
    expected_samples: int,
    successful_values: list[float],
    failed: int,
    incomplete: int,
    p50_limit_ms: float | None,
    p95_limit_ms: float | None,
    maximum_limit_ms: float | None = None,
    unknown_duration: int = 0,
    missing_release: int = 0,
    invalid_input_lines: int = 0,
    force_unverified: bool = False,
    note: str | None = None,
) -> dict[str, Any]:
    p50 = percentile(successful_values, 50)
    p95 = percentile(successful_values, 95)
    maximum = max(successful_values) if successful_values else None
    has_coverage = len(successful_values) >= expected_samples
    within_limits = (
        (p50_limit_ms is None or p50 is not None and p50 <= p50_limit_ms)
        and (p95_limit_ms is None or p95 is not None and p95 <= p95_limit_ms)
        and (maximum_limit_ms is None or maximum is not None and maximum <= maximum_limit_ms)
    )
    passed = (
        has_coverage
        and failed == 0
        and incomplete == 0
        and unknown_duration == 0
        and missing_release == 0
        and invalid_input_lines == 0
        and within_limits
        and not force_unverified
    )
    return {
        "name": name,
        "expected_successful_samples": expected_samples,
        "successful_samples": len(successful_values),
        "failed_samples": failed,
        "incomplete_samples": incomplete,
        "p50_ms": p50,
        "p95_ms": p95,
        "maximum_ms": maximum,
        "p50_limit_ms": p50_limit_ms,
        "p95_limit_ms": p95_limit_ms,
        "maximum_limit_ms": maximum_limit_ms,
        "unknown_duration_samples": unknown_duration,
        "missing_release_samples": missing_release,
        "invalid_input_lines": invalid_input_lines,
        "status": "PASS" if passed else "UNVERIFIED" if force_unverified else "FAIL",
        "pass": passed,
        "note": note,
    }


def summarize_cold_start(
    events: list[dict[str, Any]], expected_samples: int, invalid_input_lines: int
) -> dict[str, Any]:
    by_process: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        by_process[event["process_id"]].append(event)

    values: list[float] = []
    incomplete = 0
    for process_events in by_process.values():
        process_events.sort(key=lambda event: event["monotonic_ns"])
        started = first_event(process_events, "process_started", "observed")
        ready = first_event(process_events, "cold_start_ready", "ready")
        if started is None:
            continue
        if ready is None or ready["monotonic_ns"] < started["monotonic_ns"]:
            incomplete += 1
            continue
        values.append(milliseconds(ready["monotonic_ns"] - started["monotonic_ns"]))

    return metric(
        name="cold process start to ready",
        expected_samples=expected_samples,
        successful_values=values,
        failed=0,
        incomplete=incomplete,
        p50_limit_ms=None,
        p95_limit_ms=None,
        maximum_limit_ms=5_000,
        invalid_input_lines=invalid_input_lines,
        note=(
            "Ready requires the production app's microphone permission, verified model, usable "
            "hotkey, submitted audio preparation, and unpaused state. Each cold start must finish "
            "within five seconds; P50 and P95 are descriptive."
        ),
    )


def summarize_display_commit(
    sessions: dict[tuple[str, str], list[dict[str, Any]]],
    expected_samples: int,
    invalid_input_lines: int,
) -> dict[str, Any]:
    values: list[float] = []
    failed = 0
    incomplete = 0
    for events in sessions.values():
        pressed = first_event(events, "hotkey_pressed", "observed")
        if pressed is None:
            continue
        display = first_event(events, "recording_display_committed", "succeeded")
        finished = first_event(events, "session_finished")
        if display is not None and display["monotonic_ns"] >= pressed["monotonic_ns"]:
            values.append(milliseconds(display["monotonic_ns"] - pressed["monotonic_ns"]))
        elif finished and finished["result"] in {"failed", "cancelled"}:
            failed += 1
        else:
            incomplete += 1

    return metric(
        name="hotkey callback to AppKit display/isVisible commit",
        expected_samples=expected_samples,
        successful_values=values,
        failed=failed,
        incomplete=incomplete,
        p50_limit_ms=None,
        p95_limit_ms=None,
        invalid_input_lines=invalid_input_lines,
        force_unverified=True,
        note=(
            "This records an AppKit display commit, not a physical screen first frame. "
            "NFR-001 screen-first-frame verification remains incomplete."
        ),
    )


def summarize_verified_latency(
    sessions: dict[tuple[str, str], list[dict[str, Any]]],
    *,
    name: str,
    expected_samples: int,
    duration_predicate: Callable[[int], bool],
    p50_limit_ms: float | None,
    p95_limit_ms: float,
    invalid_input_lines: int,
) -> dict[str, Any]:
    values: list[float] = []
    failed = 0
    incomplete = 0
    unknown_duration = 0
    missing_release = 0
    for events in sessions.values():
        has_latency_fact = any(
            event["kind"]
            in {
                "hotkey_pressed",
                "hotkey_released",
                "audio_engine_started",
                "audio_first_buffer",
                "audio_stopped",
                "recognition_delivered",
                "ax_readback_verified",
                "copy_completed",
                "paste_requested",
                "unicode_requested",
                "session_finished",
            }
            for event in events
        )
        if not has_latency_fact:
            continue
        released = first_event(events, "hotkey_released", "observed")
        finished = first_event(events, "session_finished")
        if released is None:
            missing_release += 1
            if finished and finished["result"] in {"failed", "cancelled", "unverified", "copied"}:
                failed += 1
            else:
                incomplete += 1
            continue
        stopped = first_event(events, "audio_stopped", "succeeded")
        duration = stopped["audio_duration_ns"] if stopped else None
        if duration is None:
            unknown_duration += 1
            if finished and finished["result"] in {"failed", "cancelled", "unverified", "copied"}:
                failed += 1
            else:
                incomplete += 1
            continue
        if not duration_predicate(duration):
            continue
        verified = first_event(events, "ax_readback_verified", "verified_insertion")
        if (
            verified is not None
            and verified["monotonic_ns"] >= released["monotonic_ns"]
            and finished is not None
            and finished["result"] == "verified_insertion"
        ):
            values.append(milliseconds(verified["monotonic_ns"] - released["monotonic_ns"]))
        elif finished and finished["result"] in {"failed", "cancelled", "unverified", "copied"}:
            failed += 1
        else:
            incomplete += 1

    return metric(
        name=name,
        expected_samples=expected_samples,
        successful_values=values,
        failed=failed,
        incomplete=incomplete,
        p50_limit_ms=p50_limit_ms,
        p95_limit_ms=p95_limit_ms,
        unknown_duration=unknown_duration,
        missing_release=missing_release,
        invalid_input_lines=invalid_input_lines,
        note="Measures release callback to AX readback verification. Paste and Unicode requests never pass.",
    )


def report(arguments: argparse.Namespace) -> dict[str, Any]:
    events, invalid_lines = read_events(arguments.diagnostics_dir)
    selected_process_id = getattr(arguments, "process_id", None)
    selected_session_id = getattr(arguments, "session_id", None)
    if selected_process_id is not None:
        events = [event for event in events if event["process_id"] == selected_process_id]
    if selected_session_id is not None:
        events = [event for event in events if event["session_id"] == selected_session_id]
    if (selected_process_id is not None or selected_session_id is not None) and not events:
        raise ValueError("the requested process/session selection contains no valid diagnostics events")

    sessions = grouped_sessions(events)
    invalid_input_count = len(invalid_lines)
    short = summarize_verified_latency(
        sessions,
        name="release to AX verified insertion, audio duration at most 15 seconds",
        expected_samples=arguments.expected_short_samples,
        duration_predicate=lambda duration: duration <= 15_000_000_000,
        p50_limit_ms=1_000,
        p95_limit_ms=2_000,
        invalid_input_lines=invalid_input_count,
    )
    long = summarize_verified_latency(
        sessions,
        name="release to AX verified insertion, approximately 30 seconds audio",
        expected_samples=arguments.expected_long_samples,
        duration_predicate=lambda duration: 29_000_000_000 <= duration <= 31_000_000_000,
        p50_limit_ms=None,
        p95_limit_ms=3_500,
        invalid_input_lines=invalid_input_count,
    )
    metrics = [
        summarize_cold_start(
            events, arguments.expected_cold_start_samples, invalid_input_count
        ),
        summarize_display_commit(
            sessions, arguments.expected_display_samples, invalid_input_count
        ),
        short,
        long,
    ]
    return {
        "schema_version": 1,
        "diagnostic_event_count": len(events),
        "invalid_diagnostic_lines": invalid_lines,
        "selected_process_id": selected_process_id,
        "selected_session_id": selected_session_id,
        "metrics": metrics,
        "all_metrics_pass": not invalid_lines and all(item["pass"] for item in metrics),
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--diagnostics-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-cold-start-samples", type=int, default=3)
    parser.add_argument("--expected-display-samples", type=int, default=40)
    parser.add_argument("--expected-short-samples", type=int, default=20)
    parser.add_argument("--expected-long-samples", type=int, default=20)
    parser.add_argument("--process-id", type=uuid_argument)
    parser.add_argument("--session-id", type=uuid_argument)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        summary = report(arguments)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    except (OSError, ValueError, TypeError) as error:
        print(f"report failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
