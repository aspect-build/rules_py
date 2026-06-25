#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/../.."  # e2e workspace root

BAZEL="${BAZEL:-bazel}"
failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

if "$BAZEL" build \
    --lockfile_mode=off \
    -- @aspect_rules_py//py/tests/py_venv_conflict:_file_collision_binary \
    >"$failure_log" 2>&1; then
    echo "FAIL: permissive file-valued top-level collision was accepted" >&2
    exit 1
fi

if ! grep -Fq "only directories can be merged" "$failure_log"; then
    cat "$failure_log" >&2
    echo "FAIL: file-valued collision lacked the merge diagnostic" >&2
    exit 1
fi
