#!/bin/bash
# Check the ZIP and read-only DMG as a tester would receive them.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 archive.zip archive.dmg SHA256SUMS.txt" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZIP="$1"
DMG="$2"
CHECKSUMS="$3"
PACKAGE_NAME="Shanshuo-v0.1.0-beta.2"
TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/shanshuo-release.XXXXXX")"
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/shanshuo-dmg.XXXXXX")"
MOUNTED=0

cleanup() {
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$TEMPORARY_DIRECTORY" "$MOUNT_POINT"
}
trap cleanup EXIT

[ -f "$ZIP" ] || { echo "ZIP is missing" >&2; exit 1; }
[ -f "$DMG" ] || { echo "DMG is missing" >&2; exit 1; }
[ -f "$CHECKSUMS" ] || { echo "checksum manifest is missing" >&2; exit 1; }

(
  cd "$(dirname "$CHECKSUMS")"
  shasum -a 256 -c "$(basename "$CHECKSUMS")"
)

ditto -x -k "$ZIP" "$TEMPORARY_DIRECTORY"
ZIP_ROOT="$TEMPORARY_DIRECTORY/$PACKAGE_NAME"
[ -f "$ZIP_ROOT/docs/install.md" ] || { echo "ZIP install instructions are missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/docs/known-issues.md" ] || { echo "ZIP known issues are missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/docs/release-notes/v0.1.0-beta.2.md" ] \
  || { echo "ZIP beta.2 release notes are missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/bench/formatting/heldout.jsonl" ] \
  || { echo "ZIP formatting fixture is missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/bench/formatting/freeze.json" ] \
  || { echo "ZIP formatting freeze manifest is missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/bench/formatting/rubric.json" ] \
  || { echo "ZIP formatting rubric is missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/bench/formatting/scorer.py" ] \
  || { echo "ZIP formatting scorer is missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/bench/formatting/v1/baseline.json" ] \
  || { echo "ZIP formatting v1 baseline is missing" >&2; exit 1; }
[ -f "$ZIP_ROOT/docs/validation/minimax-formatting-v2.md" ] \
  || { echo "ZIP formatting v2 validation report is missing" >&2; exit 1; }
python3 "$ROOT/scripts/release/verify_document_links.py" "$ZIP_ROOT"
REQUIRE_RELEASE_SIGNING=1 bash "$ROOT/scripts/release/verify_bundle.sh" "$ZIP_ROOT/Shanshuo.app"

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED=1
[ -f "$MOUNT_POINT/docs/install.md" ] || { echo "DMG install instructions are missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/docs/known-issues.md" ] || { echo "DMG known issues are missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/docs/release-notes/v0.1.0-beta.2.md" ] \
  || { echo "DMG beta.2 release notes are missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/bench/formatting/heldout.jsonl" ] \
  || { echo "DMG formatting fixture is missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/bench/formatting/freeze.json" ] \
  || { echo "DMG formatting freeze manifest is missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/bench/formatting/rubric.json" ] \
  || { echo "DMG formatting rubric is missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/bench/formatting/scorer.py" ] \
  || { echo "DMG formatting scorer is missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/bench/formatting/v1/baseline.json" ] \
  || { echo "DMG formatting v1 baseline is missing" >&2; exit 1; }
[ -f "$MOUNT_POINT/docs/validation/minimax-formatting-v2.md" ] \
  || { echo "DMG formatting v2 validation report is missing" >&2; exit 1; }
[ -L "$MOUNT_POINT/Applications" ] || { echo "DMG Applications link is missing" >&2; exit 1; }
[ "$(readlink "$MOUNT_POINT/Applications")" = "/Applications" ] \
  || { echo "DMG Applications link has an unexpected target" >&2; exit 1; }
python3 "$ROOT/scripts/release/verify_document_links.py" "$MOUNT_POINT"
REQUIRE_RELEASE_SIGNING=1 bash "$ROOT/scripts/release/verify_bundle.sh" "$MOUNT_POINT/Shanshuo.app"

hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0
echo "archive verification passed"
