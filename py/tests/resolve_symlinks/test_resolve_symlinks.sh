#!/usr/bin/env bash
# Integration test: verify py_image_layer preserves symlinks in the interpreter tar.
# Validates the fix for https://github.com/aspect-build/rules_py/issues/567
#
# Builds a real py_image_layer from a py_binary and checks that the interpreter
# tar contains symlink entries (e.g. python -> python3.x) instead of full copies.

set -euo pipefail

PASS=0
FAIL=0

assert() {
    local label="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

# Find the interpreter listing in runfiles
LISTING=""
for f in $(find "$TEST_SRCDIR" -name 'interpreter_listing.txt' 2>/dev/null); do
    LISTING="$f"
    break
done

if [ -z "$LISTING" ]; then
    echo "FAIL: could not find interpreter_listing.txt in runfiles"
    exit 1
fi

echo "Inspecting interpreter layer listing:"
grep '/bin/python' "$LISTING"
echo ""

# python and python3 should be symlinks (tar -tv shows 'l' prefix for symlinks)
assert "bin/python is a symlink to python3.x" \
    grep -qE '^l.*bin/python -> python3\.' "$LISTING"

assert "bin/python3 is a symlink to python3.x" \
    grep -qE '^l.*bin/python3 -> python3\.' "$LISTING"

# The real python3.X binary should be a regular file (not a symlink)
assert "bin/python3.X is a regular file" \
    grep -qE '^-.*bin/python3\.[0-9]+ *$' "$LISTING"

# No symlink should have an absolute target (would break in containers)
assert "no absolute symlink targets" \
    bash -c '! grep -qE "^l.* -> /." "$1"' _ "$LISTING"

# The python entry should NOT be a large regular file (would mean no dedup)
assert "bin/python is not a 100MB+ regular file copy" \
    bash -c '! grep -qE "^-.* [0-9]{9,}.*bin/python *$" "$1"' _ "$LISTING"

# --- Summary ---

echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
