#!/usr/bin/env bash
#
# Asserts that well-typed targets build and that a type error fails the build.
# The workspace .bazelrc turns type checking off for the other cases, so every
# build here turns it back on. Override bazel with $BAZEL.
set -uo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"
PKG="//type-check"
ON="--@aspect_rules_py//py:type_check=true"

output_log="$(mktemp)"
trap 'rm -f "$output_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local target="$1" diagnostic="$2"
    shift 2
    if "$BAZEL" build "$ON" "$@" "$target" >"$output_log" 2>&1; then
        cat "$output_log" >&2
        fail "expected build of ${target} to fail, but it succeeded"
    fi
    if ! grep -q "$diagnostic" "$output_log"; then
        cat "$output_log" >&2
        fail "expected the ${diagnostic} diagnostic for ${target} in the build output"
    fi
}

expect_success() {
    local target="$1"
    shift
    if ! "$BAZEL" build "$ON" "$@" "$target" >"$output_log" 2>&1; then
        cat "$output_log" >&2
        fail "expected build of ${target} $* to succeed"
    fi
}

echo "== well-typed targets build and test, opted-out targets are skipped =="
if ! "$BAZEL" test "$ON" "${PKG}/..." >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected bazel test ${PKG}/... to pass with type checking on"
fi
echo "PASS"

echo "== an ill-typed py_library fails the build =="
expect_failure "${PKG}:ill_typed" "ill_typed.py:3:.*error\[invalid-assignment\]"
echo "PASS"

echo "== an ill-typed py_binary fails the build, checked against its wheels =="
expect_failure "${PKG}:ill_typed_bin" "ill_typed_main.py:3:.*error\[invalid-argument-type\]"
echo "PASS"

echo "== the global flag turns type checking off =="
expect_success "${PKG}:ill_typed" --@aspect_rules_py//py:type_check=false
echo "PASS"

echo "== --norun_validations skips type checking =="
expect_success "${PKG}:ill_typed" --norun_validations
echo "PASS"

echo "== --@aspect_rules_py//py:type_check_config reaches the checker =="
expect_success "${PKG}:ill_typed" "--@aspect_rules_py//py:type_check_config=${PKG}:ignore_invalid_assignment.ty.toml"
echo "PASS"

echo "ALL PASS: type errors fail the build"
