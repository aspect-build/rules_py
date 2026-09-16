#!/usr/bin/env bash
set -euo pipefail

# Regression test: iniconfig's lockfile carries a synthetic wheel entry with
# malformed python/abi tags (cp311_2). Before the allowlist fix, those tags
# became select conditions on nonexistent constraint targets and analysis of
# the package failed on every platform (this genquery would not even build).
#
# With the fix the malformed wheel is skipped with a warning and the package
# resolves through its valid py3-none-any wheel.

TARGETS_FILE="${TEST_SRCDIR}/_main/cases/uv-malformed-abi-tag/iniconfig_targets"
TARGETS="$(cat "$TARGETS_FILE")"

LOCKFILE="${TEST_SRCDIR}/_main/cases/uv-malformed-abi-tag/uv.lock"

errors=0

if ! grep -q 'cp311_2' "$LOCKFILE"; then
    echo "FAIL: the malformed cp311_2 wheel entry is gone from uv.lock; this regression test no longer tests anything"
    errors=$((errors + 1))
fi

if grep -q 'cp311_2' <<< "$TARGETS"; then
    echo "FAIL: malformed cp311_2 tag leaked into the dependency graph"
    errors=$((errors + 1))
fi

if ! grep -q 'whl__iniconfig__f631c04d2c48c52b' <<< "$TARGETS"; then
    echo "FAIL: the valid py3-none-any wheel is missing from the dependency graph"
    errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "Full target list:"
    echo "$TARGETS"
    exit 1
fi

echo "PASS: malformed cp311_2 wheel filtered out, iniconfig resolves via its py3-none-any wheel"
