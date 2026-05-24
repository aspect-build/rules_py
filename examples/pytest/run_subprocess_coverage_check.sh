#!/usr/bin/env bash
# Verifies that subprocess coverage data is captured in the LCOV output.
# The subprocess_coverage_test.py test calls foo.subtract() (line 5) in
# a subprocess. If subprocess coverage propagation works, the LCOV
# should contain a DA:5,<nonzero> record.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/examples/pytest/subprocess_coverage_setup_test"
MANIFEST="$TEST_SRCDIR/_main/examples/pytest/coverage_manifest.txt"

[[ -x "$LAUNCHER" ]] || { echo "launcher not found: $LAUNCHER" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

LCOV="$(mktemp -d)/coverage.lcov"

COVERAGE_MANIFEST="$MANIFEST" \
  COVERAGE_OUTPUT_FILE="$LCOV" \
  "$LAUNCHER"

[[ -s "$LCOV" ]] || { echo "LCOV file empty or missing: $LCOV" >&2; exit 1; }

# foo.py line 2 (add body) should be covered in-process.
grep -qE '^DA:2,[1-9]' "$LCOV" || {
  echo "Expected DA:2,<nonzero> (add function) not found in LCOV." >&2
  echo "LCOV contents:" >&2
  cat "$LCOV" >&2
  exit 1
}

# foo.py line 5 (subtract body) should be covered via subprocess.
grep -qE '^DA:5,[1-9]' "$LCOV" || {
  echo "Expected DA:5,<nonzero> (subtract function, called in subprocess) not found." >&2
  echo "This means subprocess coverage data was not captured." >&2
  echo "LCOV contents:" >&2
  cat "$LCOV" >&2
  exit 1
}

echo "OK: subprocess coverage captured — both add() and subtract() have DA hits."
