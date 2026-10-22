#!/usr/bin/env python3
"""Deterministic tests for the production performance report parser."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "bench/e2e/report_metrics.py"
SPEC = importlib.util.spec_from_file_location("report_metrics", MODULE_PATH)
assert SPEC and SPEC.loader
REPORT_METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT_METRICS)

MEASURE_SPEC = importlib.util.spec_from_file_location("measure", ROOT / "bench/e2e/measure.py")
assert MEASURE_SPEC and MEASURE_SPEC.loader
MEASURE = importlib.util.module_from_spec(MEASURE_SPEC)
MEASURE_SPEC.loader.exec_module(MEASURE)

SWIFT_EVENT_JSONL = os.environ.get("SHANSHUO_SWIFT_EVENT_JSONL")


def event(
    process_id: str,
    session_id: str,
    kind: str,
    result: str,
    timestamp: int,
    audio_duration_ns: int | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "kind": kind,
        "result": result,
        "process_id": process_id,
        "session_id": session_id,
        "monotonic_ns": timestamp,
        "audio_duration_ns": audio_duration_ns,
    }


class PerformanceMetricsTest(unittest.TestCase):
    def write_events(self, events: list[dict[str, object]]) -> Path:
        directory = Path(tempfile.mkdtemp(prefix="shanshuo-performance-report-"))
        lines = "".join(json.dumps(item) + "\n" for item in events)
        (directory / "performance-fixture.jsonl").write_text(lines, encoding="utf-8")
        self.addCleanup(lambda: shutil.rmtree(directory))
        return directory

    def metric_by_name(self, report: dict[str, object], prefix: str) -> dict[str, object]:
        metrics = report["metrics"]
        assert isinstance(metrics, list)
        return next(item for item in metrics if item["name"].startswith(prefix))

    def arguments(
        self,
        directory: Path,
        *,
        expected_cold_start_samples: int = 0,
        expected_display_samples: int = 0,
        expected_short_samples: int = 20,
        expected_long_samples: int = 0,
        process_id: str | None = None,
        session_id: str | None = None,
    ) -> object:
        return type(
            "Arguments",
            (),
            {
                "diagnostics_dir": directory,
                "expected_cold_start_samples": expected_cold_start_samples,
                "expected_display_samples": expected_display_samples,
                "expected_short_samples": expected_short_samples,
                "expected_long_samples": expected_long_samples,
                "process_id": process_id,
                "session_id": session_id,
            },
        )()

    def successful_short_events(self, process_id: str, session_id: str, offset: int) -> list[dict[str, object]]:
        return [
            event(process_id, session_id, "hotkey_pressed", "observed", offset),
            event(process_id, session_id, "hotkey_released", "observed", offset + 1),
            event(
                process_id,
                session_id,
                "audio_stopped",
                "succeeded",
                offset + 2,
                5_000_000_000,
            ),
            event(
                process_id,
                session_id,
                "ax_readback_verified",
                "verified_insertion",
                offset + 3,
            ),
            event(
                process_id,
                session_id,
                "session_finished",
                "verified_insertion",
                offset + 4,
            ),
        ]

    def test_report_keeps_screen_first_frame_unverified(self) -> None:
        process_id = str(uuid.uuid4())
        cold_session = str(uuid.uuid4())
        short_session = str(uuid.uuid4())
        long_session = str(uuid.uuid4())
        events = [
            event(process_id, cold_session, "process_started", "observed", 0),
            event(process_id, cold_session, "cold_start_ready", "ready", 2_000_000_000),
            event(process_id, short_session, "hotkey_pressed", "observed", 3_000_000_000),
            event(
                process_id,
                short_session,
                "recording_display_committed",
                "succeeded",
                3_050_000_000,
            ),
            event(process_id, short_session, "hotkey_released", "observed", 4_000_000_000),
            event(
                process_id,
                short_session,
                "audio_stopped",
                "succeeded",
                4_100_000_000,
                5_000_000_000,
            ),
            event(
                process_id,
                short_session,
                "ax_readback_verified",
                "verified_insertion",
                4_800_000_000,
            ),
            event(
                process_id,
                short_session,
                "session_finished",
                "verified_insertion",
                4_900_000_000,
            ),
            event(process_id, long_session, "hotkey_released", "observed", 5_000_000_000),
            event(
                process_id,
                long_session,
                "audio_stopped",
                "succeeded",
                5_100_000_000,
                30_000_000_000,
            ),
            event(
                process_id,
                long_session,
                "ax_readback_verified",
                "verified_insertion",
                7_000_000_000,
            ),
            event(
                process_id,
                long_session,
                "session_finished",
                "verified_insertion",
                7_100_000_000,
            ),
        ]
        directory = self.write_events(events)
        arguments = type(
            "Arguments",
            (),
            {
                "diagnostics_dir": directory,
                "expected_cold_start_samples": 1,
                "expected_display_samples": 1,
                "expected_short_samples": 1,
                "expected_long_samples": 1,
            },
        )()

        report = REPORT_METRICS.report(arguments)

        self.assertTrue(self.metric_by_name(report, "cold")["pass"])
        self.assertEqual(self.metric_by_name(report, "hotkey")["status"], "UNVERIFIED")
        self.assertTrue(
            self.metric_by_name(
                report,
                "release to AX verified insertion, audio duration at most",
            )["pass"]
        )
        self.assertTrue(
            self.metric_by_name(
                report,
                "release to AX verified insertion, approximately",
            )["pass"]
        )
        self.assertFalse(report["all_metrics_pass"])

    def test_failed_or_incomplete_samples_never_pass(self) -> None:
        process_id = str(uuid.uuid4())
        session_id = str(uuid.uuid4())
        directory = self.write_events(
            [
                event(process_id, session_id, "hotkey_released", "observed", 0),
                event(
                    process_id,
                    session_id,
                    "audio_stopped",
                    "succeeded",
                    1,
                    5_000_000_000,
                ),
                event(process_id, session_id, "session_finished", "unverified", 2),
            ]
        )
        arguments = type(
            "Arguments",
            (),
            {
                "diagnostics_dir": directory,
                "expected_cold_start_samples": 1,
                "expected_display_samples": 1,
                "expected_short_samples": 1,
                "expected_long_samples": 1,
            },
        )()

        report = REPORT_METRICS.report(arguments)
        short = self.metric_by_name(
            report,
            "release to AX verified insertion, audio duration at most",
        )
        self.assertEqual(short["failed_samples"], 1)
        self.assertFalse(short["pass"])
        self.assertFalse(report["all_metrics_pass"])

    def test_missing_stop_is_unknown_and_blocks_latency_pass(self) -> None:
        process_id = str(uuid.uuid4())
        events: list[dict[str, object]] = []
        for index in range(20):
            events.extend(
                self.successful_short_events(process_id, str(uuid.uuid4()), index * 10)
            )
        failed_session = str(uuid.uuid4())
        events.extend(
            [
                event(process_id, failed_session, "hotkey_pressed", "observed", 1_000),
                event(process_id, failed_session, "hotkey_released", "observed", 1_001),
                event(process_id, failed_session, "session_finished", "failed", 1_002),
            ]
        )
        report = REPORT_METRICS.report(self.arguments(self.write_events(events)))
        short = self.metric_by_name(report, "release to AX verified insertion, audio duration at most")
        self.assertEqual(short["successful_samples"], 20)
        self.assertEqual(short["failed_samples"], 1)
        self.assertEqual(short["unknown_duration_samples"], 1)
        self.assertFalse(short["pass"])

    def test_missing_release_is_counted_and_process_selection_is_explicit(self) -> None:
        selected_process = str(uuid.uuid4())
        other_process = str(uuid.uuid4())
        events: list[dict[str, object]] = []
        for index in range(20):
            events.extend(
                self.successful_short_events(selected_process, str(uuid.uuid4()), index * 10)
            )
            events.extend(
                self.successful_short_events(other_process, str(uuid.uuid4()), 10_000 + index * 10)
            )
        missing_release_session = str(uuid.uuid4())
        events.extend(
            [
                event(selected_process, missing_release_session, "hotkey_pressed", "observed", 20_000),
                event(selected_process, missing_release_session, "session_finished", "failed", 20_001),
            ]
        )
        report = REPORT_METRICS.report(
            self.arguments(self.write_events(events), process_id=selected_process)
        )
        short = self.metric_by_name(report, "release to AX verified insertion, audio duration at most")
        self.assertEqual(report["selected_process_id"], selected_process)
        self.assertEqual(short["missing_release_samples"], 1)
        self.assertEqual(short["failed_samples"], 1)
        self.assertFalse(short["pass"])

    def test_invalid_input_line_blocks_affected_metric(self) -> None:
        process_id = str(uuid.uuid4())
        events: list[dict[str, object]] = []
        for index in range(20):
            events.extend(
                self.successful_short_events(process_id, str(uuid.uuid4()), index * 10)
            )
        directory = self.write_events(events)
        fixture = directory / "performance-fixture.jsonl"
        fixture.write_text(fixture.read_text(encoding="utf-8") + "not-json\n", encoding="utf-8")
        report = REPORT_METRICS.report(self.arguments(directory))
        short = self.metric_by_name(report, "release to AX verified insertion, audio duration at most")
        self.assertEqual(short["invalid_input_lines"], 1)
        self.assertFalse(short["pass"])

    def test_schema_accepts_omitted_optional_duration_but_rejects_unknown_or_missing_keys(self) -> None:
        process_id = str(uuid.uuid4())
        session_id = str(uuid.uuid4())
        no_duration = event(process_id, session_id, "hotkey_pressed", "observed", 1)
        no_duration.pop("audio_duration_ns")
        practice_event = event(
            process_id,
            str(uuid.uuid4()),
            "practice_outcome",
            "practice_outcome_received",
            2,
        )
        practice_event.pop("audio_duration_ns")
        events, invalid_lines = REPORT_METRICS.read_events(
            self.write_events([no_duration, practice_event])
        )
        self.assertEqual(invalid_lines, [])
        self.assertEqual(len(events), 2)

        missing_required = dict(no_duration)
        missing_required.pop("kind")
        with self.assertRaises(ValueError):
            REPORT_METRICS.validate_event(missing_required)

        unknown_key = dict(no_duration)
        unknown_key["unexpected"] = True
        with self.assertRaises(ValueError):
            REPORT_METRICS.validate_event(unknown_key)

        invalid_process_id = dict(no_duration)
        invalid_process_id["process_id"] = "not-a-uuid"
        with self.assertRaises(ValueError):
            REPORT_METRICS.validate_event(invalid_process_id)

        invalid_duration = dict(no_duration)
        invalid_duration["audio_duration_ns"] = True
        with self.assertRaises(ValueError):
            REPORT_METRICS.validate_event(invalid_duration)

        report = REPORT_METRICS.report(
            self.arguments(
                self.write_events([practice_event]),
                expected_short_samples=0,
            )
        )
        short = self.metric_by_name(
            report,
            "release to AX verified insertion, audio duration at most",
        )
        self.assertEqual(short["failed_samples"], 0)
        self.assertEqual(short["unknown_duration_samples"], 0)
        self.assertEqual(report["invalid_diagnostic_lines"], [])

    @unittest.skipUnless(SWIFT_EVENT_JSONL, "Swift JSON fixture is supplied by the integration runner")
    def test_swift_encoded_optional_duration_is_read_by_python_report(self) -> None:
        assert SWIFT_EVENT_JSONL is not None
        directory = Path(SWIFT_EVENT_JSONL).parent
        raw_event = json.loads(Path(SWIFT_EVENT_JSONL).read_text(encoding="utf-8"))
        self.assertNotIn("audio_duration_ns", raw_event)
        self.assertEqual(raw_event["kind"], "practice_outcome")
        self.assertEqual(raw_event["result"], "practice_outcome_received")

        report = REPORT_METRICS.report(
            self.arguments(directory, expected_short_samples=0)
        )
        short = self.metric_by_name(
            report,
            "release to AX verified insertion, audio duration at most",
        )
        self.assertEqual(report["invalid_diagnostic_lines"], [])
        self.assertEqual(short["failed_samples"], 0)
        self.assertEqual(short["unknown_duration_samples"], 0)

    @unittest.skipUnless(SWIFT_EVENT_JSONL, "Swift JSON fixture is supplied by the integration runner")
    def test_swift_encoded_uuid_selectors_match_upper_and_lower_case(self) -> None:
        assert SWIFT_EVENT_JSONL is not None
        fixture_path = Path(SWIFT_EVENT_JSONL)
        directory = fixture_path.parent
        raw_event = json.loads(fixture_path.read_text(encoding="utf-8"))
        raw_process_id = raw_event["process_id"]
        raw_session_id = raw_event["session_id"]
        canonical_process_id = str(uuid.UUID(raw_process_id))
        canonical_session_id = str(uuid.UUID(raw_session_id))

        self.assertEqual(raw_process_id, raw_process_id.upper())
        self.assertEqual(raw_session_id, raw_session_id.upper())

        events, invalid_lines = REPORT_METRICS.read_events(directory)
        self.assertEqual(invalid_lines, [])
        self.assertEqual(events[0]["process_id"], canonical_process_id)
        self.assertEqual(events[0]["session_id"], canonical_session_id)

        for process_selector in (raw_process_id.upper(), raw_process_id.lower()):
            for session_selector in (raw_session_id.upper(), raw_session_id.lower()):
                output_path = directory / (
                    f"summary-{process_selector[0]}-{session_selector[0]}-"
                    f"{uuid.uuid4().hex}.json"
                )
                command = [
                    sys.executable,
                    str(MODULE_PATH),
                    "--diagnostics-dir",
                    str(directory),
                    "--output",
                    str(output_path),
                    "--expected-cold-start-samples",
                    "0",
                    "--expected-display-samples",
                    "0",
                    "--expected-short-samples",
                    "0",
                    "--expected-long-samples",
                    "0",
                    "--process-id",
                    process_selector,
                    "--session-id",
                    session_selector,
                ]
                result = subprocess.run(command, capture_output=True, text=True, check=False)

                self.assertEqual(result.returncode, 0, result.stderr)
                summary = json.loads(output_path.read_text(encoding="utf-8"))
                self.assertEqual(summary["diagnostic_event_count"], 1)
                self.assertEqual(summary["selected_process_id"], canonical_process_id)
                self.assertEqual(summary["selected_session_id"], canonical_session_id)

    def test_session_selection_limits_the_measurement_set(self) -> None:
        process_id = str(uuid.uuid4())
        selected_session = str(uuid.uuid4())
        other_session = str(uuid.uuid4())
        events = self.successful_short_events(process_id, selected_session, 0)
        events.extend(self.successful_short_events(process_id, other_session, 100))
        report = REPORT_METRICS.report(
            self.arguments(
                self.write_events(events),
                expected_short_samples=1,
                session_id=selected_session,
            )
        )
        short = self.metric_by_name(report, "release to AX verified insertion, audio duration at most")
        self.assertEqual(report["selected_session_id"], selected_session)
        self.assertEqual(report["diagnostic_event_count"], 5)
        self.assertTrue(short["pass"])

    def test_cold_start_requires_every_sample_to_finish_within_five_seconds(self) -> None:
        events: list[dict[str, object]] = []
        for elapsed_ns in (1_000_000_000, 1_000_000_000, 5_200_000_000):
            process_id = str(uuid.uuid4())
            session_id = str(uuid.uuid4())
            events.extend(
                [
                    event(process_id, session_id, "process_started", "observed", 0),
                    event(process_id, session_id, "cold_start_ready", "ready", elapsed_ns),
                ]
            )
        cold = REPORT_METRICS.summarize_cold_start(events, expected_samples=3, invalid_input_lines=0)
        self.assertLess(cold["p95_ms"], 5_000)
        self.assertEqual(cold["maximum_ms"], 5_200)
        self.assertFalse(cold["pass"])

    def test_cpu_parser_handles_hours_minutes_and_seconds(self) -> None:
        self.assertEqual(MEASURE.parse_cpu_seconds("01:02:03.5"), 3_723.5)
        self.assertEqual(MEASURE.parse_cpu_seconds("02:30"), 150)


if __name__ == "__main__":
    unittest.main()
