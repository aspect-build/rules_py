#!/usr/bin/env bash

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"
BUILD_ARGS=()
if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]] ||
    ! getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
    BUILD_ARGS+=(--nobuild)
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

check_toolchain() {
    local version="$1"
    local setting="$2"
    shift 2

    "$BAZEL" build \
        "${BUILD_ARGS[@]}" \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
        "--define=interpreter_setting=${setting}" \
        --extra_execution_platforms=//:linux_x86_64_exec \
        --platforms=//:linux_x86_64 \
        "$@" \
        -- "//:resolved_${setting}" "//:resolved_${setting}_exec" \
        || fail "Python ${version} did not resolve with its root config_setting"
}

check_exec_toolchain() {
    local target="$1"
    local libc="$2"
    shift 2

    "$BAZEL" build \
        "${BUILD_ARGS[@]}" \
        --lockfile_mode=off \
        --@aspect_rules_py//py:python_version=3.13 \
        "--@aspect_rules_py//uv/private/constraints/platform:platform_libc=${libc}" \
        --extra_execution_platforms=//:linux_x86_64_exec_supported \
        --platforms=//:linux_aarch64 \
        "$@" \
        -- "//:${target}" \
        || fail "${target} resolved the wrong PBS exec runtime for a ${libc} target"
}

check_toolchain 3.11 311 --define=interpreter_setting_secondary=311
check_toolchain 3.12 312
check_exec_toolchain resolved_313_exec glibc
check_exec_toolchain resolved_313_exec musl
check_exec_toolchain resolved_313_freethreaded_exec glibc \
    --@aspect_rules_py//py/private/interpreter:freethreaded=true

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

if "$BAZEL" build \
    "${BUILD_ARGS[@]}" \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.11 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --define=interpreter_setting=312 \
    --platforms=//:linux_x86_64 \
    -- //:resolved_311 >"$failure_log" 2>&1; then
    fail "Python 3.11 resolved with Python 3.12 root config_settings"
fi

if "$BAZEL" build \
    "${BUILD_ARGS[@]}" \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.11 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --define=interpreter_setting=311 \
    --extra_execution_platforms=//:linux_x86_64_exec \
    --platforms=//:linux_x86_64 \
    -- //:resolved_311_exec >"$failure_log" 2>&1; then
    fail "Python 3.11 exec tools ignored their root config_settings"
fi
if ! grep -Fq "expected PBS exec runtime" "$failure_log"; then
    cat "$failure_log" >&2
    fail "Python 3.11 exec-tool mismatch failed for an unrelated reason"
fi

if "$BAZEL" build \
    "${BUILD_ARGS[@]}" \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.13 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --extra_execution_platforms=//:linux_x86_64_exec_supported \
    --platforms=//:linux_x86_64_unsupported \
    -- //:resolved_313_exec >"$failure_log" 2>&1; then
    fail "Python 3.13 exec tools ignored target_compatible_with"
fi
if ! grep -Fq "expected PBS exec runtime" "$failure_log"; then
    cat "$failure_log" >&2
    fail "Python 3.13 selected the constrained PBS runtime"
fi

if "$BAZEL" build \
    "${BUILD_ARGS[@]}" \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.13 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --extra_execution_platforms=//:linux_x86_64_exec \
    --platforms=//:linux_aarch64 \
    -- //:resolved_313_exec >"$failure_log" 2>&1; then
    fail "Python 3.13 exec tools ignored exec_compatible_with"
fi
if ! grep -Fq "expected PBS exec runtime" "$failure_log"; then
    cat "$failure_log" >&2
    fail "Python 3.13 exec incompatibility failed for an unrelated reason"
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
