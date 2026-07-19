#!/usr/bin/env bash
# Regression for JUnit XML correctness: failure messages containing XML-1.0
# -forbidden control chars (ANSI ESC, NUL) and non-latin text must still yield
# a well-formed UTF-8 file. Drives :ctlchars_fail to write the XML, then parses
# it with a hermetic ElementTree helper (grep alone would miss malformed XML).

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/ctlchars_fail"
PARSER="$TEST_SRCDIR/_main/unittest-test-868/assert_wellformed"
for bin in "$LAUNCHER" "$PARSER"; do
  [[ -x "$bin" ]] || {
    echo "not found or not executable: $bin" >&2
    exit 1
  }
done

XML="$(mktemp -d)/test.xml"

# Fails by design (two failing tests); we only need the XML written.
XML_OUTPUT_FILE="$XML" "$LAUNCHER" || true
[[ -s "$XML" ]] || {
  echo "JUnit XML file empty or missing: $XML" >&2
  exit 1
}

# Raises on malformed XML / bad encoding; also asserts both failures recorded.
"$PARSER" "$XML"

echo "OK: control-char/unicode failures produce well-formed UTF-8 JUnit XML."
