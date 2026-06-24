#!/usr/bin/env bash
#
# These cases assert module-extension evaluation failures, so they cannot be
# sh_tests under //...; CI runs this script directly.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
BAZEL="${BAZEL:-bazel}"
failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local fixture="$1"
    local expected="$2"

    if (
        cd "$case_dir/$fixture" &&
            "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*'
    ) >"$failure_log" 2>&1; then
        fail "$fixture unexpectedly succeeded"
    fi
    if ! grep -Fq "$expected" "$failure_log"; then
        cat "$failure_log" >&2
        fail "$fixture did not report: $expected"
    fi
}

expect_failure \
    root-invalid-python \
    "module 'root_invalid_python' requested invalid python_version '3.14.3'; expected major.minor"
expect_failure \
    dependency-invalid-python \
    "module 'invalid_python_dependency' requested invalid python_version '3.14.3.1'; expected major.minor"
expect_failure \
    root-invalid-release \
    "PBS release identifiers must be eight decimal digits, got '2026-03-03'"
# Dependency modules do not own release selection. The invalid root tag must be
# reached without rejecting the dependency's deliberately invalid release tag.
expect_failure \
    dependency-invalid-release \
    "module 'dependency_invalid_release' requested invalid python_version '3.14.0a'"

echo "PASS: interpreter configuration is validated at the owning module boundary"
