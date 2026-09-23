#!/usr/bin/env bash
#
# Wrapper for the #1378 regression: models the reported shape — a shell wrapper
# that runs `runfiles_export_envvars` and then execs a nested v2 py_binary, so
# the child inherits the wrapper's merged runfiles.
#
# Bazel hands a test the materialized tree rather than the manifest, so the
# manifest-only environment is built from the tree's own `MANIFEST` — the same
# merged manifest a manifest-only parent would export. That symlink only exists
# in an unsandboxed tree, hence `local = True` on the sh_test.

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: runfiles.bash initializer cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

runfiles_export_envvars

set -uo pipefail

probe="$(rlocation _main/venv-manifest-runfiles-1378/check_manifest_imports)"
[ -x "$probe" ] || { echo "FAIL: probe binary not found via rlocation" >&2; exit 1; }

runfiles_dir="${RUNFILES_DIR:-}"
manifest="${RUNFILES_MANIFEST_FILE:-}"
if [ -z "$manifest" ] && [ -n "$runfiles_dir" ]; then
    manifest="${runfiles_dir}/MANIFEST"
fi
[ -f "$manifest" ] || { echo "FAIL: no runfiles manifest to hand down (got '$manifest')" >&2; exit 1; }

status=0

if [ -n "$runfiles_dir" ]; then
    echo "== directory only: control =="
    if ! env -u RUNFILES_MANIFEST_FILE RUNFILES_DIR="$runfiles_dir" "$probe"; then
        echo "FAIL: imports broke under directory-based runfiles" >&2
        status=1
    fi
fi

echo "== manifest only: the regression =="
if ! env -u RUNFILES_DIR RUNFILES_MANIFEST_FILE="$manifest" "$probe"; then
    echo "FAIL: the venv was not entered under manifest-only runfiles (#1378)" >&2
    status=1
fi

unittest="$(rlocation _main/venv-manifest-runfiles-1378/manifest_unittest)"
[ -x "$unittest" ] || { echo "FAIL: unittest binary not found via rlocation" >&2; exit 1; }
# A decoy at the test's runfiles-relative path in the working directory must
# never be what the driver loads.
decoy_cwd="${TEST_TMPDIR}/decoy"
mkdir -p "${decoy_cwd}/venv-manifest-runfiles-1378"
echo "raise AssertionError('decoy source loaded from the working directory')" \
    >"${decoy_cwd}/venv-manifest-runfiles-1378/manifest_unittest_test.py"

echo "== manifest only: unittest driver =="
if ! (cd "$decoy_cwd" && env -u RUNFILES_DIR RUNFILES_MANIFEST_FILE="$manifest" "$unittest"); then
    echo "FAIL: the unittest driver did not find its test files under manifest-only runfiles" >&2
    status=1
fi

if [ -n "$runfiles_dir" ]; then
    echo "== directory only: unittest driver =="
    if ! (cd "$decoy_cwd" && env -u RUNFILES_MANIFEST_FILE RUNFILES_DIR="$runfiles_dir" "$unittest"); then
        echo "FAIL: the unittest driver did not find its test files under directory runfiles" >&2
        status=1
    fi
fi

[ "$status" -eq 0 ] && echo "PASS: imports resolve from either runfiles source"
exit "$status"
