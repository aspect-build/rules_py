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

# Bytecode written into a fetched interpreter after the fact (Python running
# against the hermetic interpreter outside a write-blocking sandbox) must not
# become an input of the interpreter filegroups, or every consumer's action key
# changes the first time some module happens to be imported locally. Plant a pyc
# next to every shipped .py so the check holds for whichever glob (core or any
# feature, present or future) claims that directory.
repo=python_3_12_x86_64_unknown_linux_gnu
"$BAZEL" fetch --lockfile_mode=off --repo="@${repo}" \
    || fail "fetching ${repo} failed"
build_file="$("$BAZEL" query --lockfile_mode=off --output=location \
    -- "@${repo}//:BUILD.bazel" | head -n 1 | cut -d: -f1)"
[ -f "$build_file" ] || fail "could not locate the ${repo} repository"
repo_dir="$(dirname "$build_file")"
planted="$(mktemp)"
cleanup_planted() {
    # Files first, then the __pycache__ directories this test created.
    grep '^F ' "$planted" | cut -c3- | while read -r file; do
        rm -f -- "$file"
    done
    grep '^D ' "$planted" | cut -c3- | while read -r dir; do
        rmdir -- "$dir" 2>/dev/null || :
    done
    rm -f "$failure_log" "$planted"
}
trap cleanup_planted EXIT
if ! "$BAZEL" query --lockfile_mode=off \
    -- "kind('source file', deps(@${repo}//:files))" >"$failure_log" 2>&1; then
    cat "$failure_log" >&2
    fail "querying the ${repo} sources failed"
fi
grep -q "pydoc_data/topics.py" "$failure_log" \
    || fail "pydoc_data sources are not part of @${repo}//:files"
grep -E '/[^/]*\.py$' "$failure_log" | sed -E 's|^@[^/]*//:||; s|/[^/]*$||' | sort -u |
    while read -r dir; do
        pycache="${repo_dir}/${dir}/__pycache__"
        if [ ! -d "$pycache" ]; then
            mkdir -p "$pycache" && echo "D ${pycache}" >>"$planted"
        fi
        : >"${pycache}/stray.cpython-312.pyc" && echo "F ${pycache}/stray.cpython-312.pyc" >>"$planted"
    done
[ "$(grep -c '^F ' "$planted")" -ge 50 ] \
    || fail "planted too few pycs to be meaningful: $(grep -c '^F ' "$planted")"
if ! "$BAZEL" query --lockfile_mode=off \
    -- "kind('source file', deps(@${repo}//:files))" >"$failure_log" 2>&1; then
    cat "$failure_log" >&2
    fail "querying the ${repo} sources failed"
fi
if grep -q "__pycache__" "$failure_log"; then
    grep "__pycache__" "$failure_log" | head -n 20 >&2
    fail "bytecode written after fetch leaked into @${repo}//:files"
fi

echo "PASS: each Python version retained its root toolchain settings"
