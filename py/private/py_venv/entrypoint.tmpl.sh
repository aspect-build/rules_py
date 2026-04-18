#!/usr/bin/env bash

if {{DEBUG}}; then
    set -x
fi

{{BASH_RLOCATION_FN}}

runfiles_export_envvars

set -o errexit -o nounset -o pipefail

VENV_PATH="$(rlocation "{{VENV}}")"

source "${VENV_PATH}"/bin/activate

exec "${VENV_PATH}"/bin/python {{INTERPRETER_FLAGS}} "$@"
