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
    fail "conflicting normalized root declarations were accepted"
fi
if ! grep -q "Conflicting root toolchain settings for Python 3.11" "$failure_log"; then
    cat "$failure_log" >&2
    fail "conflicting normalized root declarations lacked a clear diagnostic"
fi

echo "PASS: each Python version retained its root toolchain settings"
