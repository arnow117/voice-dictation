#!/usr/bin/env python3
"""Reject a distribution whose packaged Markdown has a broken relative link."""

from __future__ import annotations

import re
import sys
from pathlib import Path


LINK_PATTERN = re.compile(r"\[[^]]*\]\(([^)]+)\)")


def is_external(target: str) -> bool:
    return "://" in target or target.startswith(("#", "mailto:"))


def local_target(raw_target: str) -> str:
    target = raw_target.strip().strip("<>")
    return target.partition("#")[0]


def verify_links(package_root: Path) -> list[str]:
    failures: list[str] = []
    for document in package_root.rglob("*.md"):
        for target in LINK_PATTERN.findall(document.read_text(encoding="utf-8")):
            if is_external(target):
                continue

            target_path = local_target(target)
            if target_path and not (document.parent / target_path).exists():
                relative_document = document.relative_to(package_root)
                failures.append(f"{relative_document}: {target}")
    return failures


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_document_links.py package-root", file=sys.stderr)
        return 2

    package_root = Path(sys.argv[1])
    failures = verify_links(package_root)
    if failures:
        print("broken packaged Markdown links:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1

    print("packaged Markdown links verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
