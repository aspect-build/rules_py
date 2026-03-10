#!/usr/bin/env bash
set -euo pipefail

# Regression test: watchdog ships a win_ia64 wheel that previously caused
# analysis to fail because there was no matching config_setting target.
#
# The fix filters unsupported platform tags via an allowlist, so the build
# graph is created successfully. We verify genquery ran (meaning analysis
# succeeded) and there is no win_ia64 platform constraint reference.

TARGETS_FILE="${TEST_SRCDIR}/_main/cases/uv-platform-filter-844/watchdog_targets"
TARGETS="$(cat "$TARGETS_FILE")"

errors=0

# Check for win_ia64 as a platform constraint (not as part of project name).
if echo "$TARGETS" | grep -q 'constraints/platform:win_ia64'; then
    echo "FAIL: win_ia64 platform constraint should have been filtered out"
    errors=$((errors + 1))
fi

# Also check there's no win_ia64 wheel file reference.
if echo "$TARGETS" | grep -q 'win_ia64\.whl'; then
    echo "FAIL: win_ia64 wheel should have been filtered out"
    errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "Full target list:"
    echo "$TARGETS"
    exit 1
fi

echo "PASS: watchdog analysed successfully, win_ia64 platform filtered out"
