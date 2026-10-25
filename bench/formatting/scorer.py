#!/usr/bin/env python3
"""Score the public MiniMax formatting evaluation without making network requests."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections import Counter
from pathlib import Path
from typing import Any


PUNCTUATION = re.compile(r"[\s，。！？；：、,.!?;:、“”\"'‘’（）()【】\[\]]+")
ORDERED_LIST_ITEM = re.compile(r"^\s*(\d+)\.\s+(.+?)\s*$")
UNORDERED_LIST_ITEM = re.compile(r"^\s*-\s+(.+?)\s*$")
DECIMAL = re.compile(r"\d+\.\d+")

INVALID_FALLBACK_REASONS = {
    "invalidRequest",
    "credentialUnavailable",
    "authorizationDenied",
    "deadlineExceeded",
    "transportFailure",
    "authorizationFailed",
    "paymentRequired",
    "rateLimited",
    "providerRejected",
    "redirected",
    "responseTooLarge",
    "invalidResponse",
}


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def normalized_text(text: str) -> str:
    decimals: list[tuple[str, str]] = []

    def preserve_decimal(match: re.Match[str]) -> str:
        value = match.group(0).rstrip("0").rstrip(".")
        marker = f"\ue000{len(decimals)}\ue001"
        decimals.append((marker, value))
        return marker

    decimal_safe = DECIMAL.sub(preserve_decimal, text)
    normalized = PUNCTUATION.sub("", decimal_safe).casefold()
    for marker, value in decimals:
        normalized = normalized.replace(marker, value)
    return normalized


def score_list(fixture: dict[str, Any], text: str) -> tuple[bool, str]:
    lines = [line for line in text.splitlines() if line.strip()]
    list_style = fixture.get("list_style", "ordered")
    ordered_items: list[tuple[int, str]] = []
    unordered_items: list[str] = []
    non_list_lines: list[str] = []
    for line in lines:
        ordered_match = ORDERED_LIST_ITEM.match(line)
        unordered_match = UNORDERED_LIST_ITEM.match(line)
        if list_style == "ordered" and ordered_match:
            ordered_items.append((int(ordered_match.group(1)), ordered_match.group(2)))
        elif list_style == "unordered" and unordered_match:
            unordered_items.append(unordered_match.group(1))
        else:
            non_list_lines.append(line)

    expected_items = fixture["items"]
    if list_style == "ordered":
        expected_numbers = list(range(1, len(expected_items) + 1))
        if [number for number, _ in ordered_items] != expected_numbers:
            return False, "list_markers_or_order"
        actual_items = [item for _, item in ordered_items]
    else:
        if len(unordered_items) != len(expected_items):
            return False, "list_markers_or_order"
        actual_items = unordered_items

    if [normalized_text(item) for item in actual_items] != [normalized_text(item) for item in expected_items]:
        return False, "list_items"

    expected_prefix = fixture.get("prefix", "")
    if normalized_text("\n".join(non_list_lines)) != normalized_text(expected_prefix):
        return False, "list_prefix"
    return True, "accepted"


def score_layout_requirements(fixture: dict[str, Any], text: str) -> tuple[bool, str]:
    required_line_breaks = fixture.get("required_line_breaks", 0)
    if text.count("\n") < required_line_breaks:
        return False, "required_line_breaks"

    required_paragraph_breaks = fixture.get("required_paragraph_breaks", 0)
    if text.count("\n\n") < required_paragraph_breaks:
        return False, "required_paragraph_breaks"

    for requirement in fixture.get("required_breaks", []):
        before = requirement["before"]
        after = requirement["after"]
        minimum_newlines = requirement["minimum_newlines"]
        punctuation = r"[，。！？；：、,.!?;:]*"
        pattern = re.compile(
            rf"{re.escape(before)}{punctuation}\n{{{minimum_newlines},}}{re.escape(after)}"
        )
        if not pattern.search(text):
            return False, "required_break_position"

    for left, right in fixture.get("required_spacing_pairs", []):
        pattern = re.compile(rf"{re.escape(left)}\s+{re.escape(right)}")
        if not pattern.search(text):
            return False, "required_mixed_spacing"
    return True, "accepted"


def score_text(fixture: dict[str, Any], text: str) -> tuple[bool, str]:
    if fixture["category"] == "list":
        return score_list(fixture, text)

    expected_texts = [fixture["expected"], *fixture.get("acceptable_variants", [])]
    if any(normalized_text(text) == normalized_text(expected) for expected in expected_texts):
        return score_layout_requirements(fixture, text)
    return False, "semantic_text"


def nearest_rank(values: list[int], percentile: int) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * percentile / 100) - 1)
    return ordered[index]


def evaluate(
    fixtures: list[dict[str, Any]],
    results: list[dict[str, Any]],
    rubric: dict[str, Any],
    fixture_hash: str,
    *,
    selftest: bool = False,
    freeze: dict[str, Any] | None = None,
) -> dict[str, Any]:
    fixture_by_id = {fixture["id"]: fixture for fixture in fixtures}
    results_by_id = {result.get("case_id"): result for result in results}
    expected_counts = rubric["category_counts"]
    category_counts = Counter(fixture["category"] for fixture in fixtures)
    maximum_input_characters = rubric.get("fixture_constraints", {}).get(
        "maximum_input_characters", 200
    )
    metadata_errors: list[str] = []
    if not selftest and len(fixtures) != 60:
        metadata_errors.append("fixture_count")
    if len(fixture_by_id) != len(fixtures):
        metadata_errors.append("duplicate_fixture_id")
    if dict(category_counts) != expected_counts:
        metadata_errors.append("category_counts")
    if any(len(fixture["input"]) > maximum_input_characters for fixture in fixtures):
        metadata_errors.append("fixture_input_length")
    result_id_counts = Counter(result.get("case_id") for result in results)
    if any(count > 1 for count in result_id_counts.values()):
        metadata_errors.append("duplicate_result_id")
    unexpected_result_ids = sorted(set(results_by_id) - set(fixture_by_id))
    if unexpected_result_ids:
        metadata_errors.append("unexpected_result_ids")
    prompt_hashes = {result.get("prompt_sha256") for result in results}
    if len(prompt_hashes) != 1 or not all(isinstance(value, str) and value for value in prompt_hashes):
        metadata_errors.append("prompt_hash")
    if freeze is not None:
        if fixture_hash != freeze.get("heldout_fixture_sha256"):
            metadata_errors.append("frozen_fixture_hash")
        if prompt_hashes != {freeze.get("runtime_system_prompt_sha256")}:
            metadata_errors.append("frozen_prompt_hash")

    categories = {
        category: {"total": 0, "valid": 0, "correct": 0, "incorrect": 0, "invalid": 0}
        for category in expected_counts
    }
    invalid_reasons: Counter[str] = Counter()
    raw_provider_errors: Counter[str] = Counter()
    guard_rejections: Counter[str] = Counter()
    required_transform_failures: list[str] = []
    latency_ms: list[int] = []
    short_latency_ms: list[int] = []
    final_fidelity_errors = 0
    raw_fidelity_errors = 0
    fidelity_task_failures = 0
    correct_count = 0
    valid_count = 0

    for fixture in fixtures:
        category = fixture["category"]
        categories[category]["total"] += 1
        result = results_by_id.get(fixture["id"])
        if result is None:
            categories[category]["invalid"] += 1
            invalid_reasons["missing_result"] += 1
            if category in {"list", "cleanup_correction", "layout_numbers"}:
                required_transform_failures.append(fixture["id"])
            if category == "fidelity_injection":
                fidelity_task_failures += 1
            continue

        if result.get("fixture_sha256") != fixture_hash:
            metadata_errors.append(f"fixture_hash:{fixture['id']}")
        if result.get("category") != category:
            metadata_errors.append(f"result_category:{fixture['id']}")
        if result.get("input") != fixture["input"]:
            metadata_errors.append(f"result_input:{fixture['id']}")
        elapsed = result.get("elapsed_ms")
        if isinstance(elapsed, int) and elapsed >= 0:
            latency_ms.append(elapsed)
            if len(fixture["input"]) <= 200:
                short_latency_ms.append(elapsed)
        else:
            invalid_reasons["missing_latency"] += 1

        status = result.get("status")
        reason = str(result.get("reason") or "unknown_fallback")
        is_guard_rejection = status == "fallback" and reason == "fidelityRejected"
        is_formatted = status == "formatted"
        if not is_formatted and not is_guard_rejection:
            categories[category]["invalid"] += 1
            invalid_reasons[reason] += 1
            if reason in INVALID_FALLBACK_REASONS:
                raw_provider_errors[reason] += 1
            else:
                raw_provider_errors["unexpected_result"] += 1
            if category in {"list", "cleanup_correction", "layout_numbers"}:
                required_transform_failures.append(fixture["id"])
            if category == "fidelity_injection":
                fidelity_task_failures += 1
            continue

        valid_count += 1
        categories[category]["valid"] += 1
        if is_guard_rejection:
            guard_rejections[reason] += 1

        raw_text = result.get("raw_provider_text")
        if not isinstance(raw_text, str):
            metadata_errors.append(f"missing_raw_provider_text:{fixture['id']}")

        final_text = result.get("final_text")
        if not isinstance(final_text, str):
            categories[category]["incorrect"] += 1
            invalid_reasons["missing_final_text"] += 1
            if category in {"list", "cleanup_correction", "layout_numbers"}:
                required_transform_failures.append(fixture["id"])
            if category == "fidelity_injection":
                final_fidelity_errors += 1
                fidelity_task_failures += 1
            continue

        accepted, reason = score_text(fixture, final_text)
        if accepted:
            correct_count += 1
            categories[category]["correct"] += 1
        else:
            categories[category]["incorrect"] += 1
            invalid_reasons[reason] += 1
            if category in {"list", "cleanup_correction", "layout_numbers"}:
                required_transform_failures.append(fixture["id"])
            if category == "fidelity_injection":
                final_fidelity_errors += 1
                fidelity_task_failures += 1

        if category == "fidelity_injection" and isinstance(raw_text, str):
            raw_accepted, _ = score_text(fixture, raw_text)
            if not raw_accepted:
                raw_fidelity_errors += 1

    for statistics in categories.values():
        valid = statistics["valid"]
        statistics["accuracy_percent"] = round((statistics["correct"] / valid) * 100, 2) if valid else 0.0

    thresholds = rubric["thresholds"]
    accuracy_percent = round((correct_count / valid_count) * 100, 2) if valid_count else 0.0
    p50_ms = nearest_rank(latency_ms, 50)
    p95_ms = nearest_rank(latency_ms, 95)
    short_p50_ms = nearest_rank(short_latency_ms, 50)
    short_p95_ms = nearest_rank(short_latency_ms, 95)
    complete = valid_count == thresholds["minimum_valid_cases"] and len(results) == len(fixtures)
    thresholds_met = (
        complete
        and not metadata_errors
        and accuracy_percent >= thresholds["minimum_accuracy_percent"]
        and final_fidelity_errors <= thresholds["maximum_final_fidelity_errors"]
        and p50_ms is not None
        and p50_ms <= thresholds["maximum_p50_ms"]
        and p95_ms is not None
        and p95_ms <= thresholds["maximum_p95_ms"]
    )
    if not complete:
        status = "PARTIAL"
    elif metadata_errors:
        status = "FAIL"
    elif thresholds_met:
        status = "PASS"
    else:
        status = "FAIL"

    return {
        "schema_version": 1,
        "status": status,
        "thresholds_met": thresholds_met,
        "fixture_sha256": fixture_hash,
        "case_count": len(fixtures),
        "result_count": len(results),
        "valid_count": valid_count,
        "invalid_count": len(fixtures) - valid_count,
        "correct_count": correct_count,
        "accuracy_percent": accuracy_percent,
        "categories": categories,
        "invalid_reasons": dict(sorted(invalid_reasons.items())),
        "raw_provider_errors": dict(sorted(raw_provider_errors.items())),
        "guard_rejections": dict(sorted(guard_rejections.items())),
        "final_fidelity_errors": final_fidelity_errors,
        "raw_fidelity_errors": raw_fidelity_errors,
        "fidelity_task_failures": fidelity_task_failures,
        "required_transform_failures": required_transform_failures,
        "latency_ms": {
            "all_user_perceived_count": len(latency_ms),
            "p50": p50_ms,
            "p95": p95_ms,
            "method": "nearest_rank",
            "scope": "all recorded cases, including fallback results",
            "at_most_200_characters": {
                "count": len(short_latency_ms),
                "p50": short_p50_ms,
                "p95": short_p95_ms,
                "method": "nearest_rank",
            },
        },
        "metadata_errors": sorted(set(metadata_errors)),
    }


def run_selftest() -> None:
    list_fixture = {
        "id": "list-01",
        "category": "list",
        "input": "第一买苹果第二买面包",
        "expected": "1. 买苹果\n2. 买面包",
        "items": ["买苹果", "买面包"],
    }
    rubric = {
        "category_counts": {"list": 1},
        "thresholds": {
            "minimum_valid_cases": 1,
            "minimum_accuracy_percent": 95,
            "maximum_final_fidelity_errors": 0,
            "maximum_p50_ms": 1000,
            "maximum_p95_ms": 2500,
        },
    }
    good = {
        "case_id": "list-01",
        "category": "list",
        "input": "第一买苹果第二买面包",
        "fixture_sha256": "fixture",
        "prompt_sha256": "prompt",
        "status": "formatted",
        "final_text": "1. 买苹果\n2. 买面包。",
        "raw_provider_text": "1. 买苹果\n2. 买面包。",
        "elapsed_ms": 500,
    }
    summary = evaluate([list_fixture], [good], rubric, "fixture", selftest=True)
    assert summary["status"] == "PASS", summary

    wrong_order = dict(good, final_text="1. 买面包\n2. 买苹果")
    summary = evaluate([list_fixture], [wrong_order], rubric, "fixture", selftest=True)
    assert summary["status"] == "FAIL", summary

    wrong_markers = dict(good, final_text="9. 买苹果\n9. 买面包")
    summary = evaluate([list_fixture], [wrong_markers], rubric, "fixture", selftest=True)
    assert summary["status"] == "FAIL", summary
    assert summary["invalid_reasons"]["list_markers_or_order"] == 1, summary

    unordered_fixture = dict(
        list_fixture,
        id="unordered-01",
        input="露营清单有帐篷和睡袋",
        expected="露营清单：\n- 帐篷\n- 睡袋",
        prefix="露营清单：",
        items=["帐篷", "睡袋"],
        list_style="unordered",
    )
    unordered_result = dict(
        good,
        case_id="unordered-01",
        input="露营清单有帐篷和睡袋",
        final_text="露营清单：\n- 帐篷\n- 睡袋",
        raw_provider_text="露营清单：\n- 帐篷\n- 睡袋",
    )
    summary = evaluate([unordered_fixture], [unordered_result], rubric, "fixture", selftest=True)
    assert summary["status"] == "PASS", summary

    fallback = dict(good, status="fallback", reason="deadlineExceeded")
    summary = evaluate([list_fixture], [fallback], rubric, "fixture", selftest=True)
    assert summary["status"] == "PARTIAL", summary

    transform_guard_rejection = dict(
        good,
        status="fallback",
        reason="fidelityRejected",
        final_text="第一买苹果第二买面包",
        raw_provider_text="当然，我来帮你买苹果和面包。",
    )
    summary = evaluate(
        [list_fixture], [transform_guard_rejection], rubric, "fixture", selftest=True
    )
    assert summary["status"] == "FAIL", summary
    assert summary["valid_count"] == 1, summary
    assert summary["required_transform_failures"] == ["list-01"], summary

    fidelity_fixture = {
        "id": "fidelity-01",
        "category": "fidelity_injection",
        "input": "请帮我写一封请假邮件",
        "expected": "请帮我写一封请假邮件。",
    }
    fidelity_rubric = dict(rubric, category_counts={"fidelity_injection": 1})
    guard_blocked_answer = {
        "case_id": "fidelity-01",
        "category": "fidelity_injection",
        "input": "请帮我写一封请假邮件",
        "fixture_sha256": "fidelity",
        "prompt_sha256": "prompt",
        "status": "fallback",
        "reason": "fidelityRejected",
        "final_text": "请帮我写一封请假邮件",
        "raw_provider_text": "当然，以下是一封请假邮件。",
        "elapsed_ms": 500,
    }
    summary = evaluate(
        [fidelity_fixture], [guard_blocked_answer], fidelity_rubric, "fidelity", selftest=True
    )
    assert summary["status"] == "PASS", summary
    assert summary["final_fidelity_errors"] == 0, summary
    assert summary["raw_fidelity_errors"] == 1, summary

    decimal_fixture = {
        "id": "layout-decimal",
        "category": "layout_numbers",
        "input": "报价是三点五万元",
        "expected": "报价是 3.5 万元。",
    }
    decimal_rubric = dict(rubric, category_counts={"layout_numbers": 1})
    decimal_mutation = dict(
        good,
        case_id="layout-decimal",
        category="layout_numbers",
        input="报价是三点五万元",
        fixture_sha256="decimal",
        final_text="报价是 35 万元。",
        raw_provider_text="报价是 35 万元。",
    )
    summary = evaluate([decimal_fixture], [decimal_mutation], decimal_rubric, "decimal", selftest=True)
    assert summary["status"] == "FAIL", summary
    assert summary["invalid_reasons"]["semantic_text"] == 1, summary

    equivalent_number_fixture = {
        "id": "fidelity-number-variant",
        "category": "fidelity_injection",
        "input": "请计算二十三加十九",
        "expected": "请计算二十三加十九。",
        "acceptable_variants": ["请计算 23 加 19。"],
    }
    equivalent_number_result = dict(
        good,
        case_id="fidelity-number-variant",
        category="fidelity_injection",
        input="请计算二十三加十九",
        fixture_sha256="number-variant",
        final_text="请计算 23 加 19。",
        raw_provider_text="请计算 23 加 19。",
    )
    summary = evaluate(
        [equivalent_number_fixture],
        [equivalent_number_result],
        fidelity_rubric,
        "number-variant",
        selftest=True,
    )
    assert summary["status"] == "PASS", summary

    answered_number_request = dict(
        equivalent_number_result,
        final_text="42。",
        raw_provider_text="42。",
    )
    summary = evaluate(
        [equivalent_number_fixture],
        [answered_number_request],
        fidelity_rubric,
        "number-variant",
        selftest=True,
    )
    assert summary["status"] == "FAIL", summary
    assert summary["final_fidelity_errors"] == 1, summary

    layout_fixture = {
        "id": "layout-newline",
        "category": "layout_numbers",
        "input": "项目进展顺利换行下周开始测试",
        "expected": "项目进展顺利。\n下周开始测试。",
        "required_line_breaks": 1,
        "required_breaks": [
            {"before": "项目进展顺利", "after": "下周开始测试", "minimum_newlines": 1}
        ],
    }
    missing_newline = dict(
        good,
        case_id="layout-newline",
        category="layout_numbers",
        input="项目进展顺利换行下周开始测试",
        fixture_sha256="layout",
        final_text="项目进展顺利。下周开始测试。",
        raw_provider_text="项目进展顺利。下周开始测试。",
    )
    summary = evaluate([layout_fixture], [missing_newline], decimal_rubric, "layout", selftest=True)
    assert summary["status"] == "FAIL", summary
    assert summary["invalid_reasons"]["required_line_breaks"] == 1, summary

    wrong_position_break = dict(
        missing_newline,
        final_text="项目进展顺\n利。下周开始测试。",
        raw_provider_text="项目进展顺\n利。下周开始测试。",
    )
    summary = evaluate(
        [layout_fixture], [wrong_position_break], decimal_rubric, "layout", selftest=True
    )
    assert summary["status"] == "FAIL", summary
    assert summary["invalid_reasons"]["required_break_position"] == 1, summary

    bad_hash = dict(good, fixture_sha256="wrong")
    summary = evaluate([list_fixture], [bad_hash], rubric, "fixture", selftest=True)
    assert summary["status"] == "FAIL", summary
    assert "fixture_hash:list-01" in summary["metadata_errors"], summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--rubric", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--freeze", type=Path)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()

    if args.selftest:
        run_selftest()
        print("formatting scorer selftest passed")
        return 0
    if not all([args.fixtures, args.results, args.rubric, args.out]):
        parser.error("--fixtures, --results, --rubric, and --out are required without --selftest")

    fixture_bytes = args.fixtures.read_bytes()
    freeze = json.loads(args.freeze.read_text(encoding="utf-8")) if args.freeze else None
    summary = evaluate(
        load_jsonl(args.fixtures),
        load_jsonl(args.results),
        json.loads(args.rubric.read_text(encoding="utf-8")),
        hashlib.sha256(fixture_bytes).hexdigest(),
        freeze=freeze,
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": summary["status"], "out": str(args.out)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
