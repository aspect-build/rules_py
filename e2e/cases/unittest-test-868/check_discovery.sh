#!/usr/bin/env bash
# Regression for file-based loading (vs directory discover()):
#   * each declared test runs exactly once — a nested root (child/inner_test.py
#     under a sibling of outer_test.py) is not double-run;
#   * same-basename siblings (a/same_test.py + b/same_test.py) load under
#     distinct module identities instead of raising ImportError.
# Drives :discovery_test with a synthesized XML_OUTPUT_FILE and asserts the
# exact test count.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/discovery_test"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

XML="$(mktemp -d)/test.xml"
XML_OUTPUT_FILE="$XML" "$LAUNCHER"

# Exactly four unique tests: outer, inner, a, b. Double-running the nested test
# would push this past 4; a same-basename ImportError would error the run.
grep -q 'tests="4"' "$XML" || {
  echo "Expected tests=\"4\" (each declared test loaded once)." >&2
  cat "$XML" >&2
  exit 1
}
grep -q 'failures="0"' "$XML" && grep -q 'errors="0"' "$XML" || {
  echo "Expected no failures/errors from discovery." >&2
  cat "$XML" >&2
  exit 1
}

echo "OK: 4 declared tests loaded exactly once, no same-basename collision."
