#!/usr/bin/env bash
# Regression: the driver must invoke each module's load_tests hook exactly once.
# stateful_load_test.load_tests returns its suite only on the first call; a
# second collect pass would yield an empty suite and the runner would silently
# "Ran 0 tests" (exit 0), defeating the no-tests guard.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/stateful_load"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

out="$("$LAUNCHER" 2>&1)"
grep -q "Ran 1 test" <<<"$out" || {
  echo "Expected 'Ran 1 test' — load_tests was invoked more than once." >&2
  echo "$out" >&2
  exit 1
}

echo "OK: load_tests invoked once; the single test ran."
