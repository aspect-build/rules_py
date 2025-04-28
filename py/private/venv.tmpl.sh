#!/usr/bin/env bash

{{BASH_RLOCATION_FN}}

runfiles_export_envvars

set -o errexit -o nounset -o pipefail

source "$(rlocation "{{ARG_VENV}}")"/bin/activate

exec "$(rlocation "{{ARG_VENV}}")"/bin/python {{INTERPRETER_FLAGS}} "$@"
