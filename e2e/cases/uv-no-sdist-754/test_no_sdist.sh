#!/usr/bin/env bash
set -euo pipefail

# pywin32 has only Windows wheels and no sdist. On a non-Windows host the
# whl_install repo must still generate a usable BUILD: a `whl_missing`
# incompatible default plus a select_chain whose default is wired through
# `default_target=`, not inlined as a `//conditions:default` arm.
#
# 12 platform wheels (cp311..cp314 × win32/win_amd64/win_arm64) → chain
# terminates at whl_11. whl_12 would mean the default leaked back onto arms.

TARGETS_FILE="${TEST_SRCDIR}/_main/cases/uv-no-sdist-754/pywin32_targets"
TARGETS="$(cat "$TARGETS_FILE")"

errors=0

if ! echo "$TARGETS" | grep -q ':whl_missing$'; then
    echo "FAIL: whl_missing target not found in pywin32 deps"
    errors=$((errors + 1))
fi

if echo "$TARGETS" | grep -q ':_no_sbuild$'; then
    echo "FAIL: stale _no_sbuild target present"
    errors=$((errors + 1))
fi

if ! echo "$TARGETS" | grep -q ':whl_11$'; then
    echo "FAIL: expected select_chain to terminate at whl_11"
    errors=$((errors + 1))
fi

if echo "$TARGETS" | grep -q ':whl_12$'; then
    echo "FAIL: whl_12 present — default leaked back into select_chain arms"
    errors=$((errors + 1))
fi

if ! echo "$TARGETS" | grep -q 'win_amd64'; then
    echo "FAIL: No win_amd64 wheel target found in pywin32 deps"
    errors=$((errors + 1))
fi

if ! echo "$TARGETS" | grep -q 'win32\.whl'; then
    echo "FAIL: No win32 wheel file found in pywin32 deps"
    errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "Full target list:"
    echo "$TARGETS"
    exit 1
fi

echo "PASS"
