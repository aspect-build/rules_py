#!/usr/bin/env bash
#
# The py_image_layer collision fixtures fail while their validation actions run,
# so they cannot be sh_tests under //...; CI runs this script directly.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BAZEL="${BAZEL:-bazel}"
PKG="//oci/py_image_layer"
output_log="$(mktemp)"
trap 'rm -f "$output_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_diagnostic() {
    local expected="$1"

    if ! grep -Fq "$expected" "$output_log"; then
        cat "$output_log" >&2
        fail "expected validation diagnostic: $expected"
    fi
}

echo "== cross-layer collisions must fail validation =="
if "$BAZEL" build --keep_going --output_groups=_validation -- \
    "${PKG}:_expanded_tree_collision_layers" \
    "${PKG}:_rule_group_collision_layers" \
    "${PKG}:_configured_wheel_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected cross-layer collision fixtures to fail validation"
fi
expect_diagnostic "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/generated_tree/support.py:"
expect_diagnostic "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/generated_support.py:"
if ! grep -F "py_image_layer runfile collision at ./app.runfiles/" "$output_log" | grep -Fq "/bin/pyproject-build:"; then
    cat "$output_log" >&2
    fail "expected wheel-script collision validation diagnostic"
fi

echo "== distinct interpreters at the same runfile path must fail validation =="
if "$BAZEL" build \
    --extra_toolchains="${PKG}:_configured_python_toolchain" \
    --output_groups=_validation -- \
    "${PKG}:_configured_interpreter_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected interpreter collision fixture to fail validation"
fi
expect_diagnostic "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/shared_runtime/bin/python:"

echo "== identical runfile artifacts must pass validation =="
if ! "$BAZEL" build \
    --extra_toolchains="${PKG}:_configured_python_toolchain" \
    --output_groups=_validation -- \
    "${PKG}:_configured_interpreter_shared_layers" \
    "${PKG}:_same_rule_group_source_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected shared-artifact fixtures to pass validation"
fi

echo "PASS: py_image_layer validates cross-layer and interpreter collisions"
