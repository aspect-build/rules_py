#!/usr/bin/env bash
set -euo pipefail

# Verify the colorama wheel entry in uv.lock has no `hash` field. If uv.lock is
# regenerated and gains a hash for it, this guard fails so the companion
# regression test (test_import) doesn't silently stop exercising the
# hashless-wheel code path.

LOCK="${TEST_SRCDIR}/_main/uv-dep-hashes/uv.lock"

# Extract the colorama [[package]] block, then check its wheel line for `hash`.
block="$(awk '/^\[\[package\]\]/{flag=0} /^name = "colorama"/{flag=1} flag' "$LOCK")"

if echo "$block" | grep -E '^\s*\{ url = .* hash =' >/dev/null; then
    echo "FAIL: colorama wheel entry in uv.lock has a hash; regression test invalidated."
    echo "Either remove the hash to keep the test meaningful, or delete this whole case."
    echo "--- colorama block ---"
    echo "$block"
    exit 1
fi

echo "PASS: colorama wheel entry in uv.lock is hashless"
