#!/usr/bin/env bash

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
