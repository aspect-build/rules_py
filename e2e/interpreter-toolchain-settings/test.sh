#!/usr/bin/env bash

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

check_toolchain() {
    local version="$1"
    local setting="$2"
    shift 2

    "$BAZEL" build \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
        "--define=interpreter_setting=${setting}" \
        --platforms=//:linux_x86_64 \
        "$@" \
        -- "//:resolved_${setting}" \
        || fail "Python ${version} did not resolve with its root config_setting"
}

check_toolchain 3.11 311 --define=interpreter_setting_secondary=311
check_toolchain 3.12 312

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.12 \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:uv_constraint_selected \
    || fail "rules_py Python version did not take precedence over rules_python"

"$BAZEL" build \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version=3.12 \
    -- //:uv_constraint_selected \
    || fail "rules_python Python version did not remain the uv fallback"

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//uv/private/constraints/dep_group:dep_group=interpreter-toolchain-settings \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --define=interpreter_setting=312 \
    --platforms=//:linux_x86_64 \
    --@aspect_rules_py//py:python_version=3.12 \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:uv_markers_selected //:uv_dependency_selected //:uv_minor_precision_selected \
    || fail "rules_py Python version did not take precedence for uv markers"

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//uv/private/constraints/dep_group:dep_group=interpreter-toolchain-settings \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --define=interpreter_setting=312 \
    --platforms=//:linux_x86_64 \
    --@rules_python//python/config_settings:python_version=3.12 \
    -- //:uv_markers_selected //:uv_dependency_selected //:uv_minor_precision_selected \
    || fail "rules_python Python version did not remain the uv marker fallback"

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//uv/private/constraints/dep_group:dep_group=interpreter-toolchain-settings \
    --@aspect_rules_py//py:python_version=3.11 \
    --@rules_python//python/config_settings:python_version=3.12 \
    -- //:uv_markers_not_selected //:uv_dependency_not_selected \
    || fail "rules_py Python version did not disable mismatched uv markers"

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.12 \
    --@rules_python//python/config_settings:python_version=3.12.7 \
    -- //:uv_patch_markers_selected \
    || fail "uv full-version markers did not preserve the selected patch version"

"$BAZEL" build \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version=3.12.7 \
    -- //:uv_patch_markers_selected \
    || fail "uv full-version markers did not preserve the fallback patch version"

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.12.7 \
    -- //:uv_markers_selected //:uv_patch_markers_selected \
    || fail "a rules_py patch version was not honored by uv markers"

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

if "$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.11 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --define=interpreter_setting=312 \
    --platforms=//:linux_x86_64 \
    -- //:resolved_311 >"$failure_log" 2>&1; then
    fail "Python 3.11 resolved with Python 3.12 root config_settings"
fi

if (cd conflict && "$BAZEL" query \
    --lockfile_mode=off \
    -- '@python_interpreters//:*') >"$failure_log" 2>&1; then
    fail "conflicting duplicate root declarations were accepted"
fi
if ! grep -q "Conflicting root toolchain settings for Python 3.11" "$failure_log"; then
    cat "$failure_log" >&2
    fail "conflicting duplicate root declarations lacked a clear diagnostic"
fi

echo "PASS: each Python version retained its root toolchain settings"
