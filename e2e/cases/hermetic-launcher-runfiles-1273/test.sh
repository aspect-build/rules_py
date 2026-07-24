#!/usr/bin/env bash
#
# Regression test for the hermetic-launcher 0.0.11 -> 0.0.13 upgrade
# (rules_py #1273 / hermetic-launcher #59): runfiles source selection.
#
# When Bazel exports BOTH `RUNFILES_DIR` (a materialized runfiles tree, whose
# venv `python` is a *relative* symlink into the interpreter repo) and
# `RUNFILES_MANIFEST_FILE` (the manifest, whose entries name physical bazel-out
# copies), the launcher must let the directory win: resolve the venv through
# the tree and export `RUNFILES_DIR` (not the manifest) to the child. The
# 0.0.11 launcher picked the manifest, so `sys.prefix` landed on a physical
# output and the child saw `RUNFILES_MANIFEST_FILE` instead of `RUNFILES_DIR` —
# breaking any layout that relies on the venv's relative symlinks.
#
# This can't be an `sh_test` under `//...`: it must construct the exact
# mixed-source environment against the binary's *own* tree + manifest, so it
# builds the target and runs it directly. Run from the e2e/cases workspace
# root; override bazel with $BAZEL.
set -uo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"
TARGET="//hermetic-launcher-runfiles-1273:check_runfiles_source"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== build the probe binary =="
"$BAZEL" build "$TARGET" >/dev/null 2>&1 \
    || fail "expected 'bazel build $TARGET' to succeed"

bin="$("$BAZEL" cquery --output=files "$TARGET" 2>/dev/null | head -n1)"
case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac  # cquery paths are workspace-relative
[ -x "$bin" ] || fail "could not locate built binary for $TARGET (got '$bin')"

runfiles_dir="${bin}.runfiles"
[ -d "$runfiles_dir" ] || fail "missing runfiles tree: $runfiles_dir"

# Resolve the manifest through the tree's MANIFEST symlink so both env vars name
# genuine, consistent sources (a tree and its own manifest).
manifest_link="${runfiles_dir}/MANIFEST"
manifest_file="$(readlink "$manifest_link" 2>/dev/null || echo "$manifest_link")"
[ -f "$manifest_file" ] || fail "missing runfiles manifest: $manifest_file"

echo "== both RUNFILES_DIR and RUNFILES_MANIFEST_FILE set: directory must win =="
# Run from `/` so no ambient runfiles are discovered adjacent to cwd; the env
# vars are the only sources, exercising the env-tier tie-break directly.
if ! ( cd / && \
    RUNFILES_DIR="$runfiles_dir" \
    RUNFILES_MANIFEST_FILE="$manifest_file" \
    "$bin" ); then
    fail "launcher regressed: manifest won source selection (hermetic-launcher #59)"
fi

echo "PASS: launcher prefers the runfiles directory over the manifest"
