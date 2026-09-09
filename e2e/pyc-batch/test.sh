#!/usr/bin/env bash

# `//...` runs under .bazelrc's flags and proves the launchers are sourceless.
# This checks the action graph across shard counts: the .bazelrc 1 gives one
# PyCompile per target, 2 splits the three-source library by path hash, 0 is
# per file.

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

count_compile_actions() {
    "$BAZEL" aquery "$@" "mnemonic('PyCompile', deps(//:app_test) union deps(//:cli))" 2>/dev/null | grep -c '^action ' || true
}

whole_target="$(count_compile_actions)"
test "$whole_target" = 4 || fail "expected one PyCompile per target under .bazelrc's pyc_shards=1, got $whole_target"

sharded="$(count_compile_actions --@aspect_rules_py//py:pyc_shards=2)"
test "$sharded" = 5 || fail "expected two shards to split the three-source library, got $sharded"

per_file="$(count_compile_actions --@aspect_rules_py//py:pyc_shards=0)"
test "$per_file" = 6 || fail "expected one PyCompile per source at pyc_shards=0, got $per_file"

automatic="$(count_compile_actions --@aspect_rules_py//py:pyc_shards=-1)"
test "$automatic" = 4 || fail "expected pyc_shards=-1 to give small targets one shard each, got $automatic"
many="$("$BAZEL" aquery --@aspect_rules_py//py:pyc_shards=-1 "mnemonic('PyCompile', deps(//:many))" 2>/dev/null | grep -c '^action ' || true)"
test "$many" = 2 || fail "expected pyc_shards=-1 to shard a hundred sources two ways, got $many"

invalid_log="$(mktemp)"
trap 'rm -f "$invalid_log"' EXIT
if "$BAZEL" build --@aspect_rules_py//py:pyc_shards=-2 //:cli >"$invalid_log" 2>&1; then
    fail "expected a shard count below -1 to be rejected"
fi
grep -Fq "pyc_shards must be -1 (automatic), 0 (per source) or a shard count" "$invalid_log" || fail "expected a shard-count diagnostic"

"$BAZEL" run //:cli -- bazel | grep -Fq "*** Hello, BAZEL! (v1.0) ***" || fail "cli did not run from sharded bytecode"

echo "PASS: .bazelrc sets the bytecode compilation shard count"
