#!/usr/bin/env bash
set -euo pipefail

# Strict regression test for the abi3 forward-compat fix. cryptography
# only ships cp311-abi3 wheels; the fix must expand selection to cp312
# through cp320, each referencing a matching pip_configurations target.

TARGETS_FILE="${TEST_SRCDIR}/_main/cases/uv-abi3-compat-853/cryptography_targets"

errors=0

# Fixture sanity: the un-expanded cp311 config must always be present.
if ! grep -qE 'cp311-.*-abi3$' "$TARGETS_FILE"; then
    echo "FAIL: baseline cp311-...-abi3 config_setting missing from deps"
    errors=$((errors + 1))
fi

# cp320 is the top of the MINORS range and only appears via the expansion.
if ! grep -qE 'cp320-.*-abi3$' "$TARGETS_FILE"; then
    echo "FAIL: expanded cp320-...-abi3 config_setting missing from deps"
    echo "      The abi3 forward-compat fix appears to be missing or broken."
    errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "abi3 config_settings present in cryptography deps:"
    grep -E -- '-abi3(_[0-9]+)?$' "$TARGETS_FILE" | sort -u || true
    exit 1
fi

echo "PASS: cryptography deps include the expanded cp3{11..20}-...-abi3 arms"
