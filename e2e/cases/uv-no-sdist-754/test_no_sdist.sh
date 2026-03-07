#!/usr/bin/env bash
set -euo pipefail

# Regression test for #754.
#
# The pywin32 package has only Windows wheels and no source distribution. On a
# Linux host this used to produce an empty select chain and crash during
# analysis. The fix adds an incompatible default arm so analysis succeeds.
#
# genquery produced a list of all deps of @pypi//pywin32. We verify it contains
# the _no_sbuild target (our fix) and Windows wheel targets.

# Locate the genquery output in runfiles
TARGETS_FILE="${TEST_SRCDIR}/_main/cases/uv-no-sdist-754/pywin32_targets"
TARGETS="$(cat "$TARGETS_FILE")"

errors=0

if ! echo "$TARGETS" | grep -q '_no_sbuild'; then
    echo "FAIL: _no_sbuild target not found in pywin32 deps"
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

echo "PASS: pywin32 whl_install repo generated correctly (#754)"
echo "  - _no_sbuild incompatible default present"
echo "  - Windows wheel targets present"
