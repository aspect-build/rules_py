#!/usr/bin/env bash

{{BASH_RLOCATION_FN}}

runfiles_export_envvars

set -o errexit -o nounset -o pipefail

{{PRELUDE}}

source "$(rlocation "{{VENV}}")"/bin/activate

{{PREEXEC}}

exec "$(rlocation "{{VENV}}")"/bin/python {{INTERPRETER_FLAGS}} "$@"
