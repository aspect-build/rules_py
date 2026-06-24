#!/usr/bin/env bash
# These cases assert repository and module-extension failures, so they cannot
# be sh_tests under //...; CI runs this script directly.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
BAZEL="${BAZEL:-bazel}"
output_log="$(mktemp)"
trap 'rm -f "$output_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_success() {
    local fixture="$1"
    local target="$2"

    if ! (
        cd "$case_dir/$fixture" &&
            "$BAZEL" build --lockfile_mode=off -- "$target"
    ) >"$output_log" 2>&1; then
        cat "$output_log" >&2
        fail "$fixture $target unexpectedly failed"
    fi
}

expect_failure() {
    local fixture="$1"
    local target="$2"
    local expected="$3"

    if (
        cd "$case_dir/$fixture" &&
            "$BAZEL" query --lockfile_mode=off -- "$target"
    ) >"$output_log" 2>&1; then
        fail "$fixture $target unexpectedly succeeded"
    fi
    if ! grep -Fq "$expected" "$output_log"; then
        cat "$output_log" >&2
        fail "$fixture $target did not report: $expected"
    fi
}

expect_failure \
    wheel-only \
    '@invalid_overrides//:*' \
    'build-only attributes require a source distribution, but the lock record has only wheels: resource_set, env, monitor_memory, pre_build_patches, pre_build_patch_strip, toolchains'
expect_failure \
    editable-self \
    '@invalid_editable_overrides//:*' \
    'cannot use a modification-only `uv.override_package()` annotation because the workspace supplies it'
expect_failure \
    version-mismatch \
    '@invalid_version_override//:*' \
    "selects version '2.0.0', which is absent from lock"
expect_failure \
    unmatched-lock \
    '@unmatched_lock_override//:*' \
    'has no uv.project() for that lock'

expect_success custom-build '@custom_patches//:whl'
expect_failure \
    custom-build \
    '@custom_unsupported//:*' \
    'complete `build_file_content`, which bypasses the generated `pep517_*whl(...)` call, so these attributes cannot be applied: resource_set, env, monitor_memory, toolchains'
expect_failure \
    custom-build \
    '@pure_unsupported//:*' \
    'generated pure-Python `pep517_whl(...)` call cannot apply these native-build attributes: env, toolchains'

echo "PASS: build overrides are consumed or rejected at the owning path"
