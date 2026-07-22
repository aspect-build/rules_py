#!/usr/bin/env bash
# Regression: sharding must be advertised (TEST_SHARD_STATUS_FILE touched)
# before any early return, so an empty/no-match sharded run surfaces the real
# error instead of Bazel's "the test runner did not advertise support for test
# sharding". Runs :basic_test sharded with a filter that matches nothing.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/unittest-test-868/basic_test"
[[ -x "$LAUNCHER" ]] || {
  echo "launcher not found or not executable: $LAUNCHER" >&2
  exit 1
}

STATUS="$(mktemp -d)/shard_status"

set +e
TEST_TOTAL_SHARDS=2 TEST_SHARD_INDEX=0 TEST_SHARD_STATUS_FILE="$STATUS" \
  TESTBRIDGE_TEST_ONLY=zzz_no_such_test "$LAUNCHER" >/dev/null 2>&1
rc=$?
set -e

[[ -f "$STATUS" ]] || {
  echo "Sharding was not advertised: status file was never touched." >&2
  exit 1
}
[[ "$rc" -ne 0 ]] || {
  echo "Expected a non-zero exit for a no-match filter." >&2
  exit 1
}

echo "OK: sharding advertised before the early no-match return (rc=$rc)."
