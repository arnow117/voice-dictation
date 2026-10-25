#!/usr/bin/env python3
"""Runs the scorer's deterministic known-good, known-bad, and partial-result checks."""

from scorer import run_selftest


if __name__ == "__main__":
    run_selftest()
    print("formatting scorer tests passed")
