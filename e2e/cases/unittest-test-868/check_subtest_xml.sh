#!/usr/bin/env bash
# Regression: a failing subTest must appear in the JUnit XML, not just flip the
# exit code. Drives :subtest_fail with a synthesized XML_OUTPUT_FILE (Bazel
# would normally set it) and asserts the <failure> element and failure count.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/subtest_fail"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

XML="$(mktemp -d)/test.xml"

# The i=1 subtest fails, so the launcher exits non-zero.
if XML_OUTPUT_FILE="$XML" "$LAUNCHER"; then
  echo "expected a non-zero exit from the failing subtest" >&2
  exit 1
fi

[[ -s "$XML" ]] || {
  echo "JUnit XML file empty or missing: $XML" >&2
  exit 1
}

grep -q 'failures="1"' "$XML" || {
  echo "Expected failures=\"1\" — the subtest failure was not recorded." >&2
  cat "$XML" >&2
  exit 1
}

grep -q "<failure" "$XML" || {
  echo "Expected a <failure> element for the failing subtest." >&2
  cat "$XML" >&2
  exit 1
}

echo "OK: failing subTest is recorded in the JUnit XML."
