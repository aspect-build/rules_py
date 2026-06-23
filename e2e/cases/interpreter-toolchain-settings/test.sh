#!/usr/bin/env bash

set -uo pipefail

cd "$(dirname "$0")"

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

check_toolchains() {
    local target="$1"
    local version="$2"
    shift 2

    "$BAZEL" build \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        --@rules_python//python/config_settings:python_version= \
        "$@" \
        -- "//:${target}" //:python_h_smoke \
        || fail "${target} did not resolve Python ${version} target toolchains and exec tools"
}

expect_toolchain_failure() {
    local description="$1"
    shift

    if "$BAZEL" build \
        --lockfile_mode=off \
        --@aspect_rules_py//py:python_version=3.11 \
        --@rules_python//python/config_settings:python_version= \
        "$@" \
        -- //:resolved_311 //:python_h_smoke >"$failure_log" 2>&1; then
        fail "${description} was not enforced on the Python 3.11 toolchains"
    fi
}

check_platform_toolchains() {
    local target="$1"
    local version="$2"
    local target_platform="$3"
    local exec_platform="$4"
    shift 4

    "$BAZEL" build \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        --@rules_python//python/config_settings:python_version= \
        "--platforms=${target_platform}" \
        "--extra_execution_platforms=${exec_platform}" \
        "$@" \
        -- "//:${target}" \
        || fail "${target} did not resolve the expected target and exec interpreters"
}

"$BAZEL" query --lockfile_mode=off -- \
    '@python_interpreters//:python_3_12_x86_64_unknown_linux_gnu_exec_tools' \
    >/dev/null \
    || fail "the normal GNU Linux exec-tools registration is missing"
"$BAZEL" query --lockfile_mode=off -- \
    '@python_interpreters//:python_3_14_x86_64_unknown_linux_gnu_freethreaded_exec_tools' \
    >/dev/null \
    || fail "the free-threaded GNU Linux exec-tools registration is missing"
if "$BAZEL" query --lockfile_mode=off -- \
    '@python_interpreters//:python_3_12_x86_64_unknown_linux_musl_exec_tools' \
    >"$failure_log" 2>&1; then
    fail "a normal musl Linux exec-tools registration was generated"
fi
if "$BAZEL" query --lockfile_mode=off -- \
    '@python_interpreters//:python_3_14_x86_64_unknown_linux_musl_freethreaded_exec_tools' \
    >"$failure_log" 2>&1; then
    fail "a free-threaded musl Linux exec-tools registration was generated"
fi

"$BAZEL" build \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version= \
    -- //:resolved_313 \
    || fail "an untransitioned target did not fall back to the root-default Python 3.13 toolchains"
aspect_fallback_files="$("$BAZEL" cquery \
    --lockfile_mode=off \
    --output=files \
    --@rules_python//python/config_settings:python_version= \
    -- //:uv_constraint_uses_aspect_fallback)" \
    || fail "the UV Python constraint failed with an empty rules_python version"
case "$aspect_fallback_files" in
    *aspect_selected.txt*) ;;
    *) fail "the UV Python constraint did not fall back to the Aspect root default" ;;
esac
"$BAZEL" run \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version= \
    -- //:rules_python_target_31213 \
    || fail "a rules_python target did not honor its Python 3.12.13 override"

check_toolchains \
    resolved_311 \
    3.11 \
    --define=interpreter_setting=311 \
    --define=interpreter_setting_secondary=311 \
    --platforms=//:target_only_platform \
    --extra_execution_platforms=//:exec_only_platform

check_toolchains \
    resolved_312 \
    3.12
check_platform_toolchains \
    cross_platform_312 \
    3.12 \
    //:linux_x86_64_gnu_target_platform \
    //:macos_aarch64_exec_platform
check_platform_toolchains \
    linux_gnu_target_exec_312 \
    3.12 \
    //:linux_x86_64_gnu_target_platform \
    //:linux_x86_64_glibc_exec_platform
check_platform_toolchains \
    linux_musl_target_gnu_exec_312 \
    3.12 \
    //:linux_x86_64_musl_target_platform \
    //:linux_x86_64_glibc_exec_platform
check_platform_toolchains \
    linux_musl_target_gnu_exec_314_freethreaded \
    3.14 \
    //:linux_x86_64_musl_target_platform \
    //:linux_x86_64_glibc_exec_platform \
    --define=interpreter_setting=314 \
    --@aspect_rules_py//py/private/interpreter:freethreaded=true
check_platform_toolchains \
    windows_target_macos_exec_314_freethreaded \
    3.14 \
    //:windows_x86_64_target_platform \
    //:macos_aarch64_exec_platform \
    --define=interpreter_setting=314 \
    --@aspect_rules_py//py/private/interpreter:freethreaded=true
expect_toolchain_failure \
    config_settings \
    --define=interpreter_setting=wrong \
    --define=interpreter_setting_secondary=311 \
    --platforms=//:target_only_platform \
    --extra_execution_platforms=//:exec_only_platform
expect_toolchain_failure \
    target_compatible_with \
    --define=interpreter_setting=311 \
    --define=interpreter_setting_secondary=311 \
    --platforms=//:exec_only_platform \
    --extra_execution_platforms=//:exec_only_platform
expect_toolchain_failure \
    exec_compatible_with \
    --define=interpreter_setting=311 \
    --define=interpreter_setting_secondary=311 \
    --platforms=//:target_only_platform \
    --extra_execution_platforms=//:target_only_platform
check_toolchains \
    resolved_314_freethreaded \
    3.14 \
    --define=interpreter_setting=314 \
    --@aspect_rules_py//py/private/interpreter:freethreaded=true \
    --@rules_python//python/config_settings:py_freethreaded=no
check_toolchains \
    resolved_315_prerelease \
    3.15 \
    --define=interpreter_setting=315

"$BAZEL" build \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:default_transition \
    || fail "the explicit root default did not override rules_python and initialize both version flags"
"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.14 \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:aspect_flag_transition \
    || fail "the Aspect flag did not take precedence and synchronize rules_python"
rules_python_precedence_files="$("$BAZEL" cquery \
    --lockfile_mode=off \
    --output=files \
    --@aspect_rules_py//py:python_version=3.14 \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:uv_constraint_prefers_rules_python)" \
    || fail "the UV Python constraint failed under differing version flags"
case "$rules_python_precedence_files" in
    *rules_python_selected.txt*) ;;
    *) fail "the UV Python constraint did not prefer the rules_python version" ;;
esac
"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.14 \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:aspect_full_version_transition \
    || fail "the Aspect target's full-version attribute did not take precedence and synchronize both flags"

(cd implicit-default && "$BAZEL" build --lockfile_mode=off -- //:implicit_default) \
    || fail "one root-requested version was not made the implicit default"
(cd rules-python-fallback && "$BAZEL" build \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:rules_python_fallback) \
    || fail "rules_python was not used when the Aspect default was empty"
rules_python_constraint_files="$(cd rules-python-fallback && "$BAZEL" cquery \
    --lockfile_mode=off \
    --output=files \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //:uv_constraint_uses_rules_python_fallback)" \
    || fail "the UV Python constraint did not accept the rules_python fallback"
case "$rules_python_constraint_files" in
    *rules_python_selected.txt*) ;;
    *) fail "the UV Python constraint did not select the rules_python fallback" ;;
esac

if (cd conflict && "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*') >"$failure_log" 2>&1; then
    fail "conflicting root settings for the same normalized version succeeded"
fi
if ! grep -q "Conflicting root toolchain settings for Python 3.11" "$failure_log"; then
    cat "$failure_log" >&2
    fail "conflicting root settings did not report the normalized Python version"
fi

(cd normalized-defaults && "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*' >/dev/null) \
    || fail "duplicate defaults for one normalized Python version were rejected"

if (cd missing-default && "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*') >"$failure_log" 2>&1; then
    fail "multiple root versions without an explicit default succeeded"
fi
if ! grep -q "Set is_default = True on exactly one root" "$failure_log"; then
    cat "$failure_log" >&2
    fail "a missing root default did not report how to select one"
fi

if (cd multiple-defaults && "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*') >"$failure_log" 2>&1; then
    fail "multiple explicit root defaults succeeded"
fi
if ! grep -q "Multiple root interpreters.toolchain() tags set is_default = True" "$failure_log"; then
    fail "multiple explicit defaults did not report the conflicting tags"
fi

if (cd malformed-tag-garbage && "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*') >"$failure_log" 2>&1; then
    fail "a requested Python tag with trailing garbage succeeded"
fi
if ! grep -q "got '3.14.3garbage'" "$failure_log"; then
    cat "$failure_log" >&2
    fail "a requested Python tag with trailing garbage did not identify the invalid value"
fi

if (cd malformed-tag-extra-component && "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*') >"$failure_log" 2>&1; then
    fail "a requested Python tag with a fourth component succeeded"
fi
if ! grep -q "got '3.14.3.1'" "$failure_log"; then
    cat "$failure_log" >&2
    fail "a requested Python tag with a fourth component did not identify the invalid value"
fi

"$BAZEL" build --lockfile_mode=off -- \
    //:windows_repository \
    //:freethreaded_windows_repository \
    || fail "the generated Windows PBS repositories are incomplete"

echo "PASS: target runtime/C and executor Python tools resolve with matching settings"
