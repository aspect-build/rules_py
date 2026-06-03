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
export PATH="$(dirname "${VENV_PYTHON}"):${PATH-}"

VENV_DIR="$(dirname "$(dirname "${VENV_PYTHON}")")"

# Python 3.11/3.12 PBS: getpath.py fails to resolve multi-hop relative symlinks
# that cross runfiles boundaries, falling back to the /install prefix.
# PYTHONHOME is also ignored in that path. Fix: rewrite pyvenv.cfg with an
# absolute home= so getpath.py discovers the stdlib without following symlinks.
PYTHONHOME=""
if [ -L "${VENV_PYTHON}" ]; then
    # Resolve the symlink chain to the real interpreter.
    if command -v readlink >/dev/null 2>&1 && readlink -f "${VENV_PYTHON}" >/dev/null 2>&1; then
        REAL_PYTHON="$(readlink -f "${VENV_PYTHON}")"
    elif command -v realpath >/dev/null 2>&1; then
        REAL_PYTHON="$(realpath "${VENV_PYTHON}")"
    else
        # Portable fallback: walk symlink chain manually and normalize with cd/pwd
        REAL_PYTHON="${VENV_PYTHON}"
        while [ -L "${REAL_PYTHON}" ]; do
            DIR="$(dirname "${REAL_PYTHON}")"
            TARGET="$(readlink "${REAL_PYTHON}")"
            if [ "${TARGET#/}" != "${TARGET}" ]; then
                REAL_PYTHON="${TARGET}"
            else
                REAL_PYTHON="${DIR}/${TARGET}"
            fi
            # Normalize .. components
            REAL_PYTHON="$(cd "$(dirname "${REAL_PYTHON}")" && pwd -P)/$(basename "${REAL_PYTHON}")"
        done
    fi
    PBS_BIN="$(dirname "${REAL_PYTHON}")"
    PYTHONHOME="$(dirname "${PBS_BIN}")"

    if [ -e "${VENV_DIR}/pyvenv.cfg" ] || [ -L "${VENV_DIR}/pyvenv.cfg" ]; then
        PYVENV_TMP="${VENV_DIR}/.pyvenv.cfg.$$"
        if [ -r "${VENV_DIR}/pyvenv.cfg" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    home\ =*) echo "home = ${PBS_BIN}" ;;
                    *) echo "$line" ;;
                esac
            done < "${VENV_DIR}/pyvenv.cfg" > "${PYVENV_TMP}"
        else
            cat > "${PYVENV_TMP}" <<EOF
home = ${PBS_BIN}
implementation = CPython
include-system-site-packages = false
aspect-include-user-site-packages = false
relocatable = true
EOF
        fi
        mv -f "${PYVENV_TMP}" "${VENV_DIR}/pyvenv.cfg"
    fi
fi
if [ -n "${PYTHONHOME}" ]; then
    export PYTHONHOME
fi

exec "${VENV_PYTHON}" -B -I "$(rlocation _main/py/tests/main.py)" "$@"
