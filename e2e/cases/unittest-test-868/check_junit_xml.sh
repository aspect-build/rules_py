#!/usr/bin/env bash
# Assert the unittest driver's built-in JUnit writer emits Bazel-compatible
# XML. Drives :basic_test manually with a
# synthesized XML_OUTPUT_FILE (Bazel would normally set this) and checks the
# resulting file's shape, including the <skipped> element.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/basic_test"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

XML="$(mktemp -d)/test.xml"

# basic_test has one skip and no failures, so the launcher exits 0.
XML_OUTPUT_FILE="$XML" "$LAUNCHER"

[[ -s "$XML" ]] || {
  echo "JUnit XML file empty or missing: $XML" >&2
  exit 1
}

grep -q "<testsuite " "$XML" || {
  echo "Expected a <testsuite> element." >&2
  cat "$XML" >&2
  exit 1
}

grep -q "<testcase " "$XML" || {
  echo "Expected <testcase> elements." >&2
  cat "$XML" >&2
  exit 1
}

grep -q "<skipped" "$XML" || {
  echo "Expected a <skipped> element for the skipped test." >&2
  cat "$XML" >&2
  exit 1
}

echo "OK: unittest JUnit XML has the expected testsuite/testcase/skipped shape."
