#!/usr/bin/env bash
# Run the binary at $TEST_SRCDIR/_main/examples/py_venv/$1 and fail
# unless it exits 0 AND prints the canonical cowsay banner. Used by
# the example's internal/external-venv regression tests.
set -euo pipefail

BIN="${TEST_SRCDIR}/_main/examples/py_venv/$1"
[[ -x "$BIN" ]] || { echo "ERROR: binary not executable: $BIN"; exit 1; }

out="$("$BIN")"
echo "$out"
echo "$out" | grep -q "hello py_venv!" || {
    echo "ERROR: expected 'hello py_venv!' in binary output"
    exit 1
}
