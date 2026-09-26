#!/usr/bin/env bash
#
# Bytecode-mode checks that need a build-level error or an execution log; the
# rest are Bazel tests under //pyc/... The cases/test.sh aggregator runs it.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

batch_error="$(mktemp)"
cross_dir="$(mktemp -d)"
trap 'rm -rf "$batch_error" "$cross_dir"' EXIT

echo "== batched bytecode reports shared-source action conflicts =="
if bazel build --@aspect_rules_py//py:precompile=pycache --@aspect_rules_py//py:pyc_shards=1 //pyc:batch_conflict_bin >"$batch_error" 2>&1; then
    fail "expected shared sources in batched targets to conflict"
fi
grep -Fq "conflicting actions" "$batch_error" || fail "expected conflicting-actions diagnostic"

echo "== non-Python deps keep their output path across bytecode flags =="
generated_path() {
    bazel cquery "$@" 'deps(//pyc:gen_shared_unset_bin)' --output=files 2>/dev/null | grep '/shared_generated.py$' | sort -u
}
top_level="$(bazel cquery //pyc:gen_shared_module --output=files 2>/dev/null)"
for mode in off pycache sourceless; do
    got="$(generated_path --@aspect_rules_py//py:precompile=$mode)"
    test "$got" = "$top_level" || fail "under precompile=$mode the genrule below a launcher builds at $got, not $top_level"
done

echo "== bytecode compiles once across configurations =="
# Path-mapped dbg compiles hit opt's cache. Needs a fresh output base; the
# compact execution log CI sets is disabled since Bazel refuses both logs.
bazel build --disk_cache="$cross_dir/cache" -c opt //pyc:main_from_genrule_pyc_bin
bazel build --disk_cache="$cross_dir/cache" -c dbg \
    --execution_log_compact_file= --execution_log_binary_file= \
    --execution_log_json_file="$cross_dir/dbg.json" //pyc:main_from_genrule_pyc_bin
compiles="$(grep -c '"mnemonic": "PyCompile"' "$cross_dir/dbg.json" || true)"
hits="$(grep -A 40 '"mnemonic": "PyCompile"' "$cross_dir/dbg.json" | grep -c '"cacheHit": true' || true)"
test "$compiles" -gt 0 || fail "expected a PyCompile spawn in the execution log"
test "$compiles" = "$hits" || fail "PyCompile was not path-mapped: $hits of $compiles cache hits"
