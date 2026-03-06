#!/usr/bin/env bash
# Test that the interpreter layer regex correctly classifies paths.
# Validates the fix for https://github.com/aspect-build/rules_py/issues/787

set -euo pipefail

# This must match the Starlark string value of the "interpreter" regex in
# py/private/py_image_layer.bzl (after Starlark string unescaping).
INTERPRETER_REGEX='\\.runfiles/[^/]*python_?[0-9]+(_[0-9]+)+_[a-z0-9_]+-(unknown|apple|pc)-[^/]*/'

PASS=0
FAIL=0

assert_matches() {
    local label="$1" path="$2" regex="$3"
    if echo "$path" | awk "\$0 ~ \"$regex\" { found=1 } END { exit !found }"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: expected '$label' to match: $path"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_match() {
    local label="$1" path="$2" regex="$3"
    if echo "$path" | awk "\$0 ~ \"$regex\" { found=1 } END { exit !found }"; then
        echo "FAIL: expected '$label' to NOT match: $path"
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
}

# --- Interpreter regex: should match Python interpreter repos ---

assert_matches "bzlmod interpreter (x86_64)" \
    "./app.runfiles/rules_python++python+python_3_9_x86_64-unknown-linux-gnu/bin/python3" \
    "$INTERPRETER_REGEX"

assert_matches "bzlmod interpreter (aarch64)" \
    "./app.runfiles/rules_python++python+python_3_13_6_aarch64-unknown-linux-gnu/lib/libpython3.so" \
    "$INTERPRETER_REGEX"

assert_matches "WORKSPACE interpreter (aarch64)" \
    "./app.runfiles/rules_python~0.21.0~python~python3_9_aarch64-unknown-linux-gnu/bin/python3" \
    "$INTERPRETER_REGEX"

assert_matches "macOS interpreter (x86_64)" \
    "./app.runfiles/rules_python++python+python_3_11_x86_64-apple-darwin/bin/python3" \
    "$INTERPRETER_REGEX"

assert_matches "Windows interpreter (x86_64)" \
    "./app.runfiles/rules_python++python+python_3_11_x86_64-pc-windows-msvc/python.exe" \
    "$INTERPRETER_REGEX"

assert_matches "hypothetical future interpreter repo" \
    "./app.runfiles/aspect_rules_py++interp+python_3_12_x86_64-unknown-linux-gnu/bin/python3" \
    "$INTERPRETER_REGEX"

# --- Interpreter regex: should NOT match pip/pypi package repos ---
# This is the bug from issue #787

assert_no_match "pip package with x86_64 in name (bzlmod)" \
    "./app.runfiles/rules_python++pip+pypi_313_argon2_cffi_bindings_cp36_abi3_manylinux_2_17_x86_64_b746dba8/site-packages/argon2/__init__.py" \
    "$INTERPRETER_REGEX"

assert_no_match "pip package with x86_64 (cryptography)" \
    "./app.runfiles/rules_python++pip+pypi_313_cryptography_cp39_abi3_manylinux_2_17_x86_64_58d4e912/site-packages/cryptography/__init__.py" \
    "$INTERPRETER_REGEX"

assert_no_match "pip package with aarch64 in name" \
    "./app.runfiles/rules_python++pip+pypi_313_bcrypt_cp39_cp39_manylinux_2_17_aarch64_deadbeef/site-packages/bcrypt/__init__.py" \
    "$INTERPRETER_REGEX"

assert_no_match "WORKSPACE pip package with arch" \
    "./app.runfiles/rules_python~0.21.0~pip~pypi_39_numpy_cp39_manylinux_2_17_x86_64_abc123/site-packages/numpy/__init__.py" \
    "$INTERPRETER_REGEX"

assert_no_match "uv/aspect pip package with arch" \
    "./app.runfiles/aspect_rules_py++uv+pypi_313_cryptography_cp39_abi3_manylinux_2_17_x86_64_58d4e912/site-packages/cryptography/__init__.py" \
    "$INTERPRETER_REGEX"

# --- Interpreter regex: should NOT match main repo app files ---

assert_no_match "main repo python_app" \
    "./app.runfiles/_main/python_app/__init__.py" \
    "$INTERPRETER_REGEX"

assert_no_match "main repo app file" \
    "./app.runfiles/_main/app/main.py" \
    "$INTERPRETER_REGEX"

# --- Summary ---

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
