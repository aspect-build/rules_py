#!/usr/bin/env bash
# Build closures must follow Python markers, including forks and cycles.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root
BAZEL="${BAZEL:-bazel}"

for version in 3.10 3.11; do
    expected="forky_1_install"
    if [[ "$version" == "3.11" ]]; then
        expected=$'extradep_install\nforky_2_install'
    fi

    for project in a b; do
        actual="$("$BAZEL" cquery \
            --lockfile_mode=off \
            "--@aspect_rules_py//py:python_version=${version}" \
            --output=starlark \
            --starlark:expr=target.label.name \
            -- "filter('//uv-build-graph:.*_install$', deps(@project__build_graph_${project}//private/build_deps:forky))" |
            LC_ALL=C sort)"
        if [[ "$actual" != "$expected" ]]; then
            printf 'FAIL: project %s with Python %s\nExpected:\n%s\nActual:\n%s\n' \
                "$project" "$version" "$expected" "$actual" >&2
            exit 1
        fi
    done
done

# cycleroot -> cyclea is unconditional; cyclea <-> cycleb requires Python 3.10,
# and cycleb -> cyclec is unconditional. With the cycle disabled, cyclea must
# remain installed, while cycleb and its outgoing dependency cyclec stay absent.
for version in 3.10 3.11; do
    expected=$'cyclea_install\ncycleroot_install'
    if [[ "$version" == "3.10" ]]; then
        expected=$'cyclea_install\ncycleb_install\ncyclec_install\ncycleroot_install'
    fi
    actual="$("$BAZEL" cquery \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        --output=starlark \
        --starlark:expr=target.label.name \
        -- "filter('//uv-build-graph:.*_install$', deps(@project__build_graph_a//private/build_deps:cycleroot))" |
        LC_ALL=C sort)"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: conditional cycle with Python %s\nExpected:\n%s\nActual:\n%s\n' \
            "$version" "$expected" "$actual" >&2
        exit 1
    fi
done

expect_cquery_failure() {
    local version="$1" target="$2" expected_error="$3" output
    if output="$("$BAZEL" cquery \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        -- "$target" 2>&1)"; then
        printf 'FAIL: %s unexpectedly succeeded with Python %s\n' "$target" "$version" >&2
        exit 1
    fi
    if [[ "$output" != *"$expected_error"* ]]; then
        printf 'FAIL: %s with Python %s\nExpected diagnostic:\n%s\nActual output:\n%s\n' \
            "$target" "$version" "$expected_error" "$output" >&2
        exit 1
    fi
}

expect_cquery_failure 3.9 '@project__build_graph_a//private/build_deps:forky' \
    "No locked version of build requirement 'forky' matches the current Python/platform configuration."

# Ambiguity is harmless while loading the graph, but fails when selected.
"$BAZEL" query --lockfile_mode=off -- '@project__ambig//private/build_deps:packaging' > /dev/null
expect_cquery_failure 3.11 '@project__ambig//private/build_deps:packaging' \
    "Build requirement 'packaging' has multiple locked versions without disjoint resolution markers."

echo "PASS: fork selection, conditional cycles, missing-match diagnostics, and deferred ambiguity"
