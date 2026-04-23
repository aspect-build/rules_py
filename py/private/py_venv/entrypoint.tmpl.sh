#!/usr/bin/env bash
# Launcher for py_venv targets — `bazel run :name` activates the venv
# and exec's its bin/python interactively.
#
# (py_venv_binary / py_venv_test don't use this template — they expand
# to py_binary / py_test, which use //py/private:run.tmpl.sh.)
#
# The venv is fully assembled at build time by py/private/venv.bzl —
# pyvenv.cfg, bin/python (+ versioned aliases), activate, site-packages
# symlinks, etc. All this script does is rlocation-resolve bin/python,
# export $VIRTUAL_ENV (for any child process that checks), and exec.

if {{DEBUG}}; then
    set -x
fi

{{BASH_RLOCATION_FN}}
runfiles_export_envvars

set -o errexit -o nounset -o pipefail

VENV_PYTHON="$(rlocation {{ARG_VENV_PYTHON}})"
VENV_BIN="$(dirname "${VENV_PYTHON}")"
VENV_HOME="$(dirname "${VENV_BIN}")"

export VIRTUAL_ENV="${VENV_HOME}"
export PATH="${VENV_BIN}:${PATH-}"

exec "${VENV_PYTHON}" {{INTERPRETER_FLAGS}} "$@"
