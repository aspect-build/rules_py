#!/usr/bin/env bash

# `//...` asserts ty's exit codes. This pins the diagnostics behind them, so a
# negative case cannot pass for an unrelated reason.

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

"$BAZEL" build --output_groups=rules_lint_human \
    --aspects=//tools/lint:linters.bzl%ty \
    //app:app //app:app_without_pyi_deps //app:misuse //app:transitive_misuse ||
    fail "the ty aspect did not build"

bin="$("$BAZEL" info bazel-bin)"

# Reports are colored; strip the escapes so matches don't depend on them.
report() {
    sed 's/\x1b\[[0-9;]*m//g' "$bin/app/$1.AspectRulesLintTy.out"
}

[[ -z "$(report app)" ]] || fail "ty rejected :app despite its pyi_deps: $(report app)"

expect() {
    local target="$1" diagnostic="$2"
    report "$target" | grep -q -- "$diagnostic" ||
        fail ":$target lacked '$diagnostic': $(report "$target")"
}

expect app_without_pyi_deps "unresolved-import"
expect misuse "Expected \`Point\`"
expect transitive_misuse "Expected \`Point\`"

echo "PASS: ty resolves pyi_deps, directly and through deps"
