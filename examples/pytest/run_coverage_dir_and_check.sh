#!/usr/bin/env bash
# Verifies that when COVERAGE_DIR is set, pytest_main.py writes coverage
# data to $COVERAGE_DIR/python_coverage.dat instead of COVERAGE_OUTPUT_FILE.
# This exercises the --experimental_split_coverage_postprocessing code path.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/examples/pytest/coverage_setup_test"
MANIFEST="$TEST_SRCDIR/_main/examples/pytest/coverage_manifest.txt"

[[ -x "$LAUNCHER" ]] || { echo "launcher not found or not executable: $LAUNCHER" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

COVERAGE_DIR="$WORK/cov_dir"
mkdir -p "$COVERAGE_DIR"

# COVERAGE_OUTPUT_FILE is set to a different path to prove the output does NOT
# go there when COVERAGE_DIR is present.
DECOY_OUTPUT="$WORK/decoy.lcov"

COVERAGE_MANIFEST="$MANIFEST" \
  COVERAGE_DIR="$COVERAGE_DIR" \
  COVERAGE_OUTPUT_FILE="$DECOY_OUTPUT" \
  "$LAUNCHER"

EXPECTED="$COVERAGE_DIR/python_coverage.dat"
[[ -s "$EXPECTED" ]] || {
  echo "Expected $EXPECTED to exist and be non-empty." >&2
  echo "Contents of COVERAGE_DIR:" >&2
  ls -la "$COVERAGE_DIR" >&2
  exit 1
}

# The decoy file must NOT have been written.
[[ ! -f "$DECOY_OUTPUT" ]] || {
  echo "Coverage was incorrectly written to COVERAGE_OUTPUT_FILE ($DECOY_OUTPUT) instead of COVERAGE_DIR." >&2
  exit 1
}

# Basic shape check: SF: record must point to foo.py.
grep -qE '^SF:.*examples/pytest/foo\.py$' "$EXPECTED" || {
  echo "Expected SF: record for examples/pytest/foo.py not found." >&2
  cat "$EXPECTED" >&2
  exit 1
}

echo "OK: coverage data written to \$COVERAGE_DIR/python_coverage.dat as expected."
