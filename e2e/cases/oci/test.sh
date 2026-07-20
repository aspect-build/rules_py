#!/usr/bin/env bash
#
# Multi-binary destination collisions are discovered by the validation action,
# so the expected-failure case cannot be an sh_test under //....
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

echo "== versioned pure-wheel children must share an image =="
if ! "$BAZEL" build --output_groups=_validation -- \
    "${PKG}:_configured_pure_wheel_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected the two-version pure-wheel image to validate"
fi

echo "== unversioned wheel scripts must fail shared-image validation =="
if "$BAZEL" build --output_groups=_validation -- \
    "${PKG}:_configured_wheel_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected the shared wheel-script destination to fail validation"
fi
if ! grep -F "py_image_layer runfile collision at ./app.runfiles/" "$output_log" | grep -Fq "/bin/pyproject-build:"; then
    cat "$output_log" >&2
    fail "expected the pyproject-build destination-collision diagnostic"
fi

echo "PASS: expanded multi-binary destinations validate correctly"

echo "== a relocated scalar launcher must not overwrite runfile data =="
if "$BAZEL" build --output_groups=_validation -- \
    "${PKG}:_scalar_launcher_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected the relocated scalar launcher destination to fail validation"
fi
if ! grep -Fq "py_image_layer runfile collision at ./app/bin/_scalar_launcher_collision:" "$output_log"; then
    cat "$output_log" >&2
    fail "expected the relocated scalar launcher collision diagnostic"
fi

echo "PASS: relocated scalar launcher destinations validate correctly"

echo "== a scalar strip prefix must not turn its launcher into a file-prefix conflict =="
if "$BAZEL" build --output_groups=_validation -- \
    "${PKG}:_scalar_strip_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected the scalar strip-prefix destination to fail validation"
fi
if ! grep -Fq "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/_scalar_strip_collision/data.txt:" "$output_log"; then
    cat "$output_log" >&2
    fail "expected the scalar strip-prefix collision diagnostic"
fi

echo "PASS: scalar strip-prefix destinations validate correctly"
