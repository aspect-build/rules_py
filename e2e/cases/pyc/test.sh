#!/usr/bin/env bash
# Integration checks that require changing a top-level build setting or
# inspecting Bazel's action/configuration graph.
set -euo pipefail

cd "$(dirname "$0")/../../.."
BAZEL="${BAZEL:-bazel}"
RULES="//py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== PEX ignores first-party bytecode mode =="
"$BAZEL" test --"${RULES}":pyc=pyc "${RULES}/tests/py-pex-binary:all"

echo "== PEX rejects an explicitly bytecode-configured binary =="
pex_error="$(mktemp)"
trap 'rm -f "$pex_error"' EXIT
if "$BAZEL" build "${RULES}/tests/py-pex-binary:pyc_only_noop_pex" >"$pex_error" 2>&1; then
    fail "expected explicitly bytecode-configured PEX input to fail"
fi
if ! grep -Fq "to use pyc=source" "$pex_error"; then
    fail "expected PEX bytecode-mode diagnostic"
fi

echo "== direct venv consumers follow the global flag; explicit pyc pins =="
# The py_venv_exec macro's `pyc` defaults to empty = inherit --//py:pyc, for
# macro and direct rule users alike; an explicit value pins the mode.
"$BAZEL" test --"${RULES}":pyc=pyc "${RULES}/tests/py-venv-multi-exec:test_entry_b"
"$BAZEL" build --"${RULES}":pyc=pyc "${RULES}/tests/py-venv-multi-exec:test_pyc_source_python_310"
pinned_manifest="bazel-bin/py/tests/py-venv-multi-exec/test_pyc_source_python_310.runfiles_manifest"
test -f "$pinned_manifest" || fail "missing runfiles manifest $pinned_manifest"
if grep -q '\.pyc' "$pinned_manifest"; then
    fail "explicit pyc=source did not pin source mode under a pyc flag"
fi

echo "== source mode creates no PyCompile actions and ships no bytecode =="
# The bytecode aspect only rides the pyc_venv edge, so a source-mode binary
# analyzes no compile actions and its runfiles carry no .pyc files.
source_actions="$("$BAZEL" aquery --"${RULES}":pyc=source "mnemonic('PyCompile', deps(${RULES}/tests/main-from-genrule:main_from_genrule_bin))" | grep -c '^action ' || true)"
test "$source_actions" = 0 || fail "source mode unexpectedly analyzed bytecode compile actions"
"$BAZEL" build --"${RULES}":pyc=source "${RULES}/tests/main-from-genrule:main_from_genrule_bin"
manifest="bazel-bin/py/tests/main-from-genrule/main_from_genrule_bin.runfiles_manifest"
test -f "$manifest" || fail "missing runfiles manifest $manifest"
if grep -q '\.pyc' "$manifest"; then
    fail "source mode unexpectedly shipped .pyc runfiles"
fi

echo "== all bytecode modes share one configured venv and its compilation actions =="
# Bytecode mode must not fork the venv's configuration: the sibling venv
# resolves to a single configured target under source, pyc, and pyc_only
# launchers alike.
venv_configs="$("$BAZEL" cquery "deps(${RULES}/tests/py-venv-multi-exec:test_pyc_source, 1) union deps(${RULES}/tests/py-venv-multi-exec:test_pyc_cache, 1) union deps(${RULES}/tests/py-venv-multi-exec:test_pyc_only, 1)" | grep -c ':shared_venv ' || true)"
test "$venv_configs" = 1 || fail "expected one configured shared_venv across all pyc modes, got $venv_configs"
single_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(${RULES}/tests/py-venv-multi-exec:test_pyc_cache))" | grep -c '^action ' || true)"
combined_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(set(${RULES}/tests/py-venv-multi-exec:test_pyc_source ${RULES}/tests/py-venv-multi-exec:test_pyc_cache ${RULES}/tests/py-venv-multi-exec:test_pyc_only)))" | grep -c '^action ' || true)"
test "$single_count" -gt 0 || fail "expected shared venv to compile first-party bytecode"
test "$single_count" = "$combined_count" || fail "shared venv bytecode compilation was duplicated ($single_count vs $combined_count)"

echo "== bytecode forks per python version, not per pyc mode =="
# Six launchers — {source, pyc, pyc_only} x {3.10, 3.12} — share one venv
# label. Expect one configured venv and one PyCompile action set per python
# version: the version axis forks, the mode axis must not multiply it.
MULTI="${RULES}/tests/py-venv-multi-exec"
v310_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(${MULTI}:test_pyc_python_310))" | grep -c '^action ' || true)"
v312_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(${MULTI}:test_pyc_python_312))" | grep -c '^action ' || true)"
matrix_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(set(${MULTI}:test_pyc_source_python_310 ${MULTI}:test_pyc_source_python_312 ${MULTI}:test_pyc_python_310 ${MULTI}:test_pyc_python_312 ${MULTI}:test_pyc_only_python_310 ${MULTI}:test_pyc_only_python_312)))" | grep -c '^action ' || true)"
test "$v310_count" -gt 0 || fail "expected 3.10 bytecode compile actions"
test "$v312_count" -gt 0 || fail "expected 3.12 bytecode compile actions"
test "$matrix_count" = "$((v310_count + v312_count))" ||
    fail "pyc/version matrix duplicated compile actions ($matrix_count vs $v310_count + $v312_count)"
versioned_configs="$("$BAZEL" cquery "deps(${MULTI}:test_pyc_source_python_310, 1) union deps(${MULTI}:test_pyc_source_python_312, 1) union deps(${MULTI}:test_pyc_python_310, 1) union deps(${MULTI}:test_pyc_python_312, 1) union deps(${MULTI}:test_pyc_only_python_310, 1) union deps(${MULTI}:test_pyc_only_python_312, 1)" | grep -c ':shared_versioned_venv ' || true)"
test "$versioned_configs" = 2 || fail "expected one configured shared_versioned_venv per python version, got $versioned_configs"

echo "== bytecode cross-compiles via the exec interpreter =="
# At least one of these target platforms is foreign to any CI host, so a
# successful build proves the compile action ran a host-runnable interpreter.
# Identical bytes across target platforms prove the pyc is platform-independent
# (the invariant remote caches rely on).
cross_dir="$(mktemp -d)"
trap 'rm -f "$pex_error"; rm -rf "$cross_dir"' EXIT
for plat in linux_amd64 linux_arm64; do
    "$BAZEL" build --platforms="${RULES}/tests/main-from-genrule:${plat}" \
        "${RULES}/tests/main-from-genrule:main_from_genrule_pyc_bin"
    pyc_path="$("$BAZEL" cquery --platforms="${RULES}/tests/main-from-genrule:${plat}" \
        --output=files "${RULES}/tests/main-from-genrule:main_from_genrule_pyc_bin" | grep '\.pyc$')"
    test -n "$pyc_path" || fail "no .pyc output for platform ${plat}"
    cp "$pyc_path" "$cross_dir/${plat}.pyc"
done
cmp "$cross_dir/linux_amd64.pyc" "$cross_dir/linux_arm64.pyc" ||
    fail "cross-compiled bytecode differs between target platforms"

echo "== launchers remain in the top-level configuration =="
launcher_path="$("$BAZEL" cquery --output=starlark --starlark:expr='target.files.to_list()[0].path' "${RULES}/tests/main-from-genrule:main_from_genrule_bin")"
case "$launcher_path" in
    *-ST-*) fail "launcher was transitioned away from the top-level configuration: $launcher_path" ;;
    bazel-out/*/bin/*) ;;
    *) fail "unexpected launcher output path: $launcher_path" ;;
esac
