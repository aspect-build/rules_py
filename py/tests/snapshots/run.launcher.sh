#!/usr/bin/env bash
# NB: we don't use a path from @bazel_tools//tools/sh:toolchain_type because that's configured for the exec
# configuration, while this script executes in the target configuration at runtime.

# This is a special comment for py_pex_binary to find the python entrypoint.
# __PEX_PY_BINARY_ENTRYPOINT__ _main/py/tests/main.py


# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
# https://github.com/bazelbuild/bazel/blob/master/tools/bash/runfiles/runfiles.bash
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: runfiles.bash initializer cannot find $f. An executable rule may have forgotten to expose it in the runfiles, or the binary may require RUNFILES_DIR to be set."; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

runfiles_export_envvars

set -o errexit -o nounset -o pipefail

VENV_PYTHON="$(rlocation _main/py/tests/.snapshot_venv/bin/python)"
VENV_BIN="$(dirname "${VENV_PYTHON}")"
export VIRTUAL_ENV="$(dirname "${VENV_BIN}")"
export PATH="${VENV_BIN}:${PATH-}"

# Set all the env vars here, just before we launch
export BAZEL_TARGET="//py/tests:snapshot_exec"
export BAZEL_WORKSPACE="_main"
export BAZEL_TARGET_NAME="snapshot_exec"

exec "${VENV_PYTHON}" -B -I "$(rlocation _main/py/tests/main.py)" "$@"
