#!/usr/bin/env bash
# Regression for the unittest driver's argv handling:
#   * runtime `args` (forwarded to sys.argv) are parsed, not ignored (`-k`);
#   * a `-k` / --test_filter that matches nothing fails loudly (typo guard);
#   * unknown args are rejected rather than silently dropped;
#   * accepted flags like --failfast still let a passing suite succeed.
# Drives the :basic_test launcher directly (args on the command line reach
# sys.argv the same way the `args` attribute does).

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/basic_test"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

# -k narrows to a single test.
out="$("$LAUNCHER" -k test_membership 2>&1)"
grep -q "Ran 1 test" <<<"$out" || {
  echo "Expected -k test_membership to run exactly one test." >&2
  echo "$out" >&2
  exit 1
}

# Repeated -k ORs (native unittest semantics): both tests run.
out="$("$LAUNCHER" -k test_pass -k test_membership 2>&1)"
grep -q "Ran 2 tests" <<<"$out" || {
  echo "Expected repeated -k to OR to two tests (native unittest -k)." >&2
  echo "$out" >&2
  exit 1
}

# A wildcard -k uses fnmatch, not a literal match.
out="$("$LAUNCHER" -k '*embership*' 2>&1)"
grep -q "Ran 1 test" <<<"$out" || {
  echo "Expected wildcard -k '*embership*' to match test_membership." >&2
  echo "$out" >&2
  exit 1
}

# -k matching nothing fails loudly.
if "$LAUNCHER" -k zzz_nomatch >/dev/null 2>&1; then
  echo "Expected a no-match -k filter to fail." >&2
  exit 1
fi

# --test_filter (TESTBRIDGE_TEST_ONLY) matching nothing fails loudly.
if TESTBRIDGE_TEST_ONLY=zzz_nomatch "$LAUNCHER" >/dev/null 2>&1; then
  echo "Expected a no-match --test_filter to fail." >&2
  exit 1
fi

# Unknown args are rejected, not silently ignored.
if "$LAUNCHER" --not-a-real-flag >/dev/null 2>&1; then
  echo "Expected an unknown arg to be rejected." >&2
  exit 1
fi

# --failfast is accepted; the passing suite still succeeds.
"$LAUNCHER" --failfast >/dev/null 2>&1 || {
  echo "Expected --failfast run of a passing suite to succeed." >&2
  exit 1
}

# Three distinct verbosity modes (unittest 0/1/2). Verbose prints a line per
# test (method names); default prints a compact progress line; quiet suppresses
# progress entirely — so the output grows verbose > default > quiet, and only
# verbose names the tests.
v_out="$("$LAUNCHER" -v 2>&1)"
d_out="$("$LAUNCHER" 2>&1)"
q_out="$("$LAUNCHER" -q 2>&1)"

grep -q "test_pass" <<<"$v_out" || {
  echo "Expected verbose (-v) output to name tests (test_pass)." >&2
  echo "$v_out" >&2
  exit 1
}
if grep -q "test_pass" <<<"$d_out"; then
  echo "Expected default output NOT to name tests." >&2
  echo "$d_out" >&2
  exit 1
fi
v_lines=$(wc -l <<<"$v_out")
d_lines=$(wc -l <<<"$d_out")
q_lines=$(wc -l <<<"$q_out")
if ! { [ "$v_lines" -gt "$d_lines" ] && [ "$d_lines" -gt "$q_lines" ]; }; then
  echo "Expected output volume verbose > default > quiet, got $v_lines/$d_lines/$q_lines." >&2
  exit 1
fi

echo "OK: unittest driver parses args, rejects unknowns, guards empty filters, and honors -v/-q."
