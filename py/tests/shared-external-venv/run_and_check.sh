#!/usr/bin/env bash
# Runs the named py_binary target against the shared venv and asserts
# its stdout contains the expected substring. Fails verbosely if the
# binary errors out (e.g. import error from a broken venv wiring) or
# if the substring is missing.

set -euo pipefail

binary="$1"
expected="$2"

LAUNCHER="$TEST_SRCDIR/_main/py/tests/shared-external-venv/${binary}"

[[ -x "$LAUNCHER" ]] || { echo "launcher not found: $LAUNCHER" >&2; exit 1; }

output=$("$LAUNCHER")

if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: expected substring '$expected' not found in binary output." >&2
    echo "Output was:" >&2
    echo "$output" >&2
    exit 1
fi

echo "OK: '$binary' produced expected '$expected' substring via shared venv."
