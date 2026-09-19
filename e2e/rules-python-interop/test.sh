#!/usr/bin/env bash
#
# Either version flag must select the interpreter in a module where both
# rulesets register toolchains — rules_py's hub honours @rules_python's flag as
# a fallback for legacy consumers. Each check either resolves a toolchain
# without a py_* version transition or runs the selected interpreter, so a
# broken flag reports the default version rather than the requested one.
set -euo pipefail

cd "$(dirname "$0")"  # e2e/rules-python-interop

BAZEL="${BAZEL:-bazel}"

# The repo check is what makes the rules_python-flag runs meaningful at 3.12:
# rules_python's own default toolchain reports that version too, so a broken
# fallback in rules_py's hub would be invisible if only the version were
# compared.
check_resolved_runtime() {
    local flag="$1"
    local target="$2"
    local version="$3"
    local repo="$4"
    local got
    got="$("$BAZEL" run --lockfile_mode=off "--${flag}=${version}" \
        -- "${target}" 2>/dev/null)"
    if [[ "${got}" != "${version} "* || "${got}" != *"${repo}"* ]]; then
        echo "FAIL: set ${flag}=${version}, expected ${target} to report ${version} from ${repo}, got ${got}" >&2
        exit 1
    fi
}

# version_check is a py_binary with no python_version attr, and it asserts its
# own interpreter against the expected version passed as argv[1]. The py_*
# transition normalizes both flags, so either entry point reaches every
# version — including 3.11, which only rules_python provisions.
for version in 3.10 3.11 3.12 3.13 3.14; do
    "$BAZEL" run \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        -- //:version_check "${version}"

    "$BAZEL" run \
        --lockfile_mode=off \
        "--@rules_python//python/config_settings:python_version=${version}" \
        -- //:version_check "${version}"
done

# report_version and report_exec_version resolve their toolchain with no py_*
# transition in between, so they see only the flag the caller set. That keeps
# both flags inside rules_py's lane: rules_python's 3.11 toolchain is gated on
# rules_python's own flag, and the exec-tools toolchain type has no
# rules_python provider at all.
for version in 3.10 3.12 3.13 3.14; do
    check_resolved_runtime @aspect_rules_py//py:python_version //:report_version "${version}" python_interpreters
    check_resolved_runtime @aspect_rules_py//py:python_version //:report_exec_version "${version}" python_interpreters

    check_resolved_runtime @rules_python//python/config_settings:python_version //:report_version "${version}" python_interpreters
    check_resolved_runtime @rules_python//python/config_settings:python_version //:report_exec_version "${version}" python_interpreters
done

# Only rules_python's flag reaches its own 3.11 toolchain; rules_py's hub
# declares no 3.11, so nothing of ours shadows it.
check_resolved_runtime @rules_python//python/config_settings:python_version //:report_version 3.11 rules_python

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.13 \
    -- \
    //:python_launcher

launcher_version="$(<"$("$BAZEL" info --lockfile_mode=off bazel-bin)/python_launcher.txt")"
if [[ "${launcher_version}" != "3.13" ]]; then
    echo "FAIL: rules_py Python version selected launcher ${launcher_version}, expected 3.13" >&2
    exit 1
fi

echo "PASS: rules_py Python version selected the 3.13 launcher"

"$BAZEL" test --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.13 \
    -- \
    //reset-data-edges:passthrough_terminals_test \
    //reset-data-edges:pyc_resets_test \
    //reset-data-edges:reset_data_edges_test \
    //reset-data-edges:shared_binaries_test

# Exercise rules_python's source-retention modes.
retention=@rules_python//python/config_settings:precompile_source_retention
"$BAZEL" test --lockfile_mode=off \
    --@aspect_rules_py//py:pyc=pyc_only --test_env=EXPECT_PYC=pyc_only \
    --test_env=EXPECT_SOURCE_IN_RUNFILES=1 \
    -- //:rules_python_dep_test
"$BAZEL" test --lockfile_mode=off "--${retention}=omit_source" \
    -- //:rules_python_dep_test
"$BAZEL" test --lockfile_mode=off "--${retention}=omit_source" \
    --@aspect_rules_py//py:pyc=pyc --test_env=EXPECT_PYC=pyc \
    -- //:rules_python_dep_test
"$BAZEL" test --lockfile_mode=off "--${retention}=omit_source" \
    --@aspect_rules_py//py:pyc=pyc_only --test_env=EXPECT_PYC=pyc_only \
    -- //:rules_python_dep_test

# Exercise rules_python with precompilation disabled.
precompile=@rules_python//python/config_settings:precompile
"$BAZEL" test --lockfile_mode=off "--${precompile}=force_disabled" \
    --@aspect_rules_py//py:pyc=pyc_only --test_env=EXPECT_PYC=pyc_only \
    --test_env=EXPECT_SOURCE_IN_RUNFILES=1 \
    -- //:rules_python_dep_test

# Verify which compiler produces each layout.
actions="$(mktemp)"
query="$(mktemp)"
trap 'rm -f "$actions" "$query"' EXIT
echo 'mnemonic("PyCompile", deps(//:rules_python_dep_test))' >"$query"
check_compiler() {
    local flag="$1" output="$2" tool="$3" count
    "$BAZEL" aquery --lockfile_mode=off --output=text "$flag" \
        --query_file="$query" >"$actions" 2>/dev/null
    count="$(awk -v RS='' -v out="$output" 'match($0, /Outputs: \[[^]]*\]/) && index(substr($0, RSTART, RLENGTH), out) { c++ } END { print c + 0 }' "$actions")"
    if [[ "$count" != 1 ]]; then
        echo "FAIL: ${flag}: expected one action producing ${output}, got ${count}" >&2
        exit 1
    fi
    if ! awk -v RS='' -v out="$output" 'match($0, /Outputs: \[[^]]*\]/) && index(substr($0, RSTART, RLENGTH), out)' "$actions" | grep -Fq "$tool"; then
        echo "FAIL: ${flag}: expected ${output} to be compiled by ${tool}" >&2
        exit 1
    fi
}
check_compiler "--${retention}=keep_source" "__pycache__/precompiled_lib.cpython-312.pyc" precompiler
check_compiler "--${retention}=keep_source" "/precompiled_lib.pyc" pyc_compile.py
check_compiler "--${retention}=omit_source" "__pycache__/precompiled_lib.cpython-312.pyc" pyc_compile.py
check_compiler "--${retention}=omit_source" "/precompiled_lib.pyc" precompiler
check_compiler "--${precompile}=force_disabled" "__pycache__/precompiled_lib.cpython-312.pyc" pyc_compile.py
check_compiler "--${precompile}=force_disabled" "/precompiled_lib.pyc" pyc_compile.py
