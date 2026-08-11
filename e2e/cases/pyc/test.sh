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

echo "== direct venv consumers remain source-mode under a global flag =="
"$BAZEL" test --"${RULES}":pyc=pyc "${RULES}/tests/py-venv-multi-exec:test_entry_b"

echo "== source mode creates no PyCompile actions =="
source_actions="$("$BAZEL" aquery --"${RULES}":pyc=source "mnemonic('PyCompile', deps(${RULES}/tests/main-from-genrule:main_from_genrule_bin))")"
if grep -q "PyCompile" <<<"$source_actions"; then
    printf '%s\n' "$source_actions" >&2
    fail "source mode unexpectedly analyzed bytecode compile actions"
fi

echo "== configured pyc consumers share compilation actions =="
single_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(${RULES}/tests/py-venv-multi-exec:test_pyc_cache))" | grep -c '^action ' || true)"
combined_count="$("$BAZEL" aquery "mnemonic('PyCompile', deps(set(${RULES}/tests/py-venv-multi-exec:test_pyc_cache ${RULES}/tests/py-venv-multi-exec:test_pyc_only)))" | grep -c '^action ' || true)"
test "$single_count" -gt 0 || fail "expected shared venv to compile first-party bytecode"
test "$single_count" = "$combined_count" || fail "shared venv bytecode compilation was duplicated ($single_count vs $combined_count)"

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
