#!/usr/bin/env bash
#
# Regression test for package-patch failure handling. Asserts a build *fails*,
# so it can't be an sh_test under //...; CI runs it directly (fixtures are
# `manual`-tagged). Run from the e2e workspace root; override bazel with $BAZEL.
set -uo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"
PKG="//patch-failure"
# install_dir is in an output group — request it so the patch action runs.
OG="--output_groups=install_dir"

stderr_log="$(mktemp)"
trap 'rm -f "$stderr_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== broken patch must fail the build =="
if "$BAZEL" build "$OG" "${PKG}:broken_patch" >/dev/null 2>"$stderr_log"; then
    cat "$stderr_log" >&2
    fail "expected build of ${PKG}:broken_patch to fail, but it succeeded"
fi
if ! grep -qi "failed to apply patch" "$stderr_log"; then
    cat "$stderr_log" >&2
    fail "expected the patch-failure diagnostic on stderr"
fi
echo "PASS: failing patch aborts the build with a stderr diagnostic"

echo "== offset patch must apply with no .orig backups =="
if ! "$BAZEL" build "$OG" "${PKG}:offset_patch" >/dev/null 2>"$stderr_log"; then
    cat "$stderr_log" >&2
    fail "expected build of ${PKG}:offset_patch to succeed"
fi

tree="$("$BAZEL" info bazel-bin 2>/dev/null)/patch-failure/offset_patch.install"
if [ -n "$(find "$tree" -name '*.orig' -print)" ]; then
    fail "patch left .orig backups behind in ${tree}"
fi
grep -q "PATCHED_WITH_OFFSET" "${tree}/marker.txt" \
    || fail "offset patch was not applied to ${tree}/marker.txt"
echo "PASS: offset patch applied cleanly with no .orig backups"

echo "ALL PASS: package-patch failure handling is correct"
