#!/usr/bin/env bash
#
# These checks load generated repositories from a nested module, so CI runs
# them directly rather than through the parent e2e workspace.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir" || exit 1

BAZEL="${BAZEL:-bazel}"
if ! "$BAZEL" test --lockfile_mode=off -- \
    //:regular \
    //:freethreaded; then
    echo "FAIL: prerelease runtime metadata did not match" >&2
    exit 1
fi

echo "PASS: PBS runtime metadata matches the selected interpreter"
