#!/usr/bin/env bash
#
# The fixture intentionally makes a wheel patch invalidate repository-inspected
# package metadata, so CI runs it directly rather than in the parent wildcard.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir" || exit 1

BAZEL="${BAZEL:-bazel}"
stderr_log="$(mktemp)"
trap 'rm -f "$stderr_log"' EXIT

if "$BAZEL" test \
    -- \
    //cases/uv-patched-topology-change:consumer \
    > /dev/null 2> "$stderr_log"; then
    echo "FAIL: expected the topology-changing wheel patch to fail" >&2
    exit 1
fi

diagnostic="Post-install patch changed observed package classification: zope"
if ! grep -Fq "$diagnostic" "$stderr_log"; then
    cat "$stderr_log" >&2
    echo "FAIL: expected the patched-wheel topology diagnostic" >&2
    exit 1
fi

echo "PASS: topology-changing wheel patch was rejected"
