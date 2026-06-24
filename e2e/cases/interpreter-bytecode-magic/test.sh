#!/usr/bin/env bash
#
# These checks load generated repositories from a nested module, so CI runs
# them directly rather than through the parent e2e workspace.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir" || exit 1

BAZEL="${BAZEL:-bazel}"
if ! "$BAZEL" test --lockfile_mode=off -- \
    //:python_3_13 \
    //:python_3_13_freethreaded \
    //:python_3_13_windows \
    //:python_3_14 \
    //:python_3_14_freethreaded \
    //:python_3_14_windows; then
    echo "FAIL: PBS bytecode magic does not match its interpreter" >&2
    exit 1
fi

echo "PASS: PBS runtime pairs expose their bytecode magic"
