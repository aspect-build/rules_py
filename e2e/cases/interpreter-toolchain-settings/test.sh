#!/usr/bin/env bash
# Successful resolution is covered by BUILD tests. This script keeps cases
# whose expected result is an analysis or module-evaluation failure.

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

if "$BAZEL" build \
    --nobuild \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.11 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --//:interpreter_setting=312 \
    --platforms=//:linux_x86_64 \
    -- //:resolved_311 >"$failure_log" 2>&1; then
    fail "Python 3.11 resolved with Python 3.12 root config_settings"
fi

if "$BAZEL" build \
    --nobuild \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.11 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --//:interpreter_setting=311 \
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
    --nobuild \
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
    --nobuild \
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

echo "PASS: invalid toolchain configurations were rejected"
