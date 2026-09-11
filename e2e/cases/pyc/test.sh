#!/usr/bin/env bash
#
# Bytecode-mode checks that need a top-level build setting or a look at
# Bazel's action/configuration graph. The cases/test.sh aggregator runs it.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

count_compile_actions() {
    bazel aquery "$@" 2>/dev/null | grep -c '^action ' || true
}

echo "== PEX ignores first-party bytecode mode =="
bazel test --@aspect_rules_py//py:pyc=pyc //pyc:pex_no_bytecode_test

echo "== PEX rejects an explicitly bytecode-configured binary =="
pex_error="$(mktemp)"
cross_dir="$(mktemp -d)"
trap 'rm -rf "$pex_error" "$cross_dir"' EXIT
if bazel build //pyc:pyc_only_noop_pex >"$pex_error" 2>&1; then
    fail "expected explicitly bytecode-configured PEX input to fail"
fi
grep -Fq "to use pyc=source" "$pex_error" || fail "expected PEX bytecode-mode diagnostic"

echo "== venv_link launchers ignore the global flag =="
bazel build --@aspect_rules_py//py:pyc=pyc_only //pyc:link_bin.venv_link

echo "== direct venv consumers follow the global flag; explicit pyc pins =="
bazel test --@aspect_rules_py//py:pyc=pyc //pyc:test_pyc_default
bazel build --@aspect_rules_py//py:pyc=pyc //pyc:test_pyc_source_python_313
pinned_manifest="bazel-bin/pyc/test_pyc_source_python_313.runfiles_manifest"
test -f "$pinned_manifest" || fail "missing runfiles manifest $pinned_manifest"
if grep -q '\.pyc' "$pinned_manifest"; then
    fail "explicit pyc=source did not pin source mode under a pyc flag"
fi

echo "== source mode declares but never executes or ships bytecode =="
source_actions="$(count_compile_actions --@aspect_rules_py//py:pyc=source "mnemonic('PyCompile', deps(//pyc:test_pyc_default))")"
test "$source_actions" -gt 0 || fail "expected auto-declared bytecode compile actions in source mode"
bazel build --@aspect_rules_py//py:pyc=source //pyc:test_pyc_default
manifest="bazel-bin/pyc/test_pyc_default.runfiles_manifest"
test -f "$manifest" || fail "missing runfiles manifest $manifest"
if grep -q '\.pyc' "$manifest"; then
    fail "source mode unexpectedly shipped .pyc runfiles"
fi

echo "== rule targets in srcs are opaque to bytecode =="
genrule_actions="$(count_compile_actions "mnemonic('PyCompile', deps(//pyc:main_from_genrule_bin))")"
test "$genrule_actions" = 0 || fail "genrule-in-srcs unexpectedly declared bytecode compile actions"

echo "== all bytecode modes share one configured venv and its compilation actions =="
venv_configs="$(bazel cquery "deps(//pyc:test_pyc_default, 1) union deps(//pyc:test_pyc_cache, 1) union deps(//pyc:test_pyc_only, 1)" 2>/dev/null | grep -c ':shared_venv ' || true)"
test "$venv_configs" = 1 || fail "expected one configured shared_venv across all pyc modes, got $venv_configs"
single_count="$(count_compile_actions "mnemonic('PyCompile', deps(//pyc:test_pyc_cache))")"
combined_count="$(count_compile_actions "mnemonic('PyCompile', deps(set(//pyc:test_pyc_default //pyc:test_pyc_cache //pyc:test_pyc_only)))")"
test "$single_count" -gt 0 || fail "expected shared venv to compile first-party bytecode"
test "$single_count" = "$combined_count" || fail "shared venv bytecode compilation was duplicated ($single_count vs $combined_count)"

echo "== bytecode forks per python version, not per pyc mode =="
v313_count="$(count_compile_actions "mnemonic('PyCompile', deps(//pyc:test_pyc_python_313))")"
v312_count="$(count_compile_actions "mnemonic('PyCompile', deps(//pyc:test_pyc_python_312))")"
matrix_count="$(count_compile_actions "mnemonic('PyCompile', deps(set(//pyc:test_pyc_source_python_313 //pyc:test_pyc_source_python_312 //pyc:test_pyc_python_313 //pyc:test_pyc_python_312 //pyc:test_pyc_only_python_313 //pyc:test_pyc_only_python_312)))")"
test "$v313_count" -gt 0 || fail "expected 3.13 bytecode compile actions"
test "$v312_count" -gt 0 || fail "expected 3.12 bytecode compile actions"
test "$matrix_count" = "$((v313_count + v312_count))" ||
    fail "pyc/version matrix duplicated compile actions ($matrix_count vs $v313_count + $v312_count)"
versioned_configs="$(bazel cquery "deps(//pyc:test_pyc_source_python_313, 1) union deps(//pyc:test_pyc_source_python_312, 1) union deps(//pyc:test_pyc_python_313, 1) union deps(//pyc:test_pyc_python_312, 1) union deps(//pyc:test_pyc_only_python_313, 1) union deps(//pyc:test_pyc_only_python_312, 1)" 2>/dev/null | grep -c ':shared_versioned_venv ' || true)"
test "$versioned_configs" = 2 || fail "expected one configured shared_versioned_venv per python version, got $versioned_configs"

echo "== bytecode cross-compiles via the exec interpreter =="
for plat in linux_amd64 linux_arm64; do
    bazel build "--platforms=//pyc:${plat}" //pyc:main_from_genrule_pyc_bin
    pyc_path="$(bazel cquery "--platforms=//pyc:${plat}" --output=files //pyc:main_from_genrule_pyc_bin 2>/dev/null | grep '\.pyc$')"
    test -n "$pyc_path" || fail "no .pyc output for platform ${plat}"
    cp "$pyc_path" "$cross_dir/${plat}.pyc"
done
cmp "$cross_dir/linux_amd64.pyc" "$cross_dir/linux_arm64.pyc" ||
    fail "cross-compiled bytecode differs between target platforms"

echo "== launchers remain in the top-level configuration =="
launcher_path="$(bazel cquery --output=starlark --starlark:expr='target.files.to_list()[0].path' //pyc:main_from_genrule_bin 2>/dev/null)"
case "$launcher_path" in
    *-ST-*) fail "launcher was transitioned away from the top-level configuration: $launcher_path" ;;
    bazel-out/*/bin/*) ;;
    *) fail "unexpected launcher output path: $launcher_path" ;;
esac
