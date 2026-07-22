#!/usr/bin/env bash
# Regression: fail-fast must honor both the driver-local `--failfast` arg and
# Bazel's `--test_runner_fail_fast` (forwarded as TESTBRIDGE_TEST_RUNNER_FAIL_FAST=1).
# :twofail has two failing methods; with fail-fast only the first runs.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/twofail"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

# Baseline: without fail-fast, both failing methods run.
out="$("$LAUNCHER" 2>&1 || true)"
grep -q "Ran 2 tests" <<<"$out" || {
  echo "Expected 'Ran 2 tests' with no fail-fast." >&2
  echo "$out" >&2
  exit 1
}

# Driver-local --failfast stops after the first failure.
out="$("$LAUNCHER" --failfast 2>&1 || true)"
grep -q "Ran 1 test" <<<"$out" || {
  echo "Expected 'Ran 1 test' with --failfast." >&2
  echo "$out" >&2
  exit 1
}

# Bazel's env flag must have the same effect.
out="$(TESTBRIDGE_TEST_RUNNER_FAIL_FAST=1 "$LAUNCHER" 2>&1 || true)"
grep -q "Ran 1 test" <<<"$out" || {
  echo "Expected 'Ran 1 test' with TESTBRIDGE_TEST_RUNNER_FAIL_FAST=1." >&2
  echo "$out" >&2
  exit 1
}

echo "OK: fail-fast honors --failfast and TESTBRIDGE_TEST_RUNNER_FAIL_FAST."
