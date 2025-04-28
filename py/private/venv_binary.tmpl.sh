#!/usr/bin/env bash

{{BASH_RLOCATION_FN}}

runfiles_export_envvars

set -o errexit -o nounset -o pipefail

# Psuedo-activate; would be better if we could just source "the" activate scripts
source "$(rlocation "{{ARG_VENV}}")"/bin/activate

# And punt to the virtualenv's "interpreter" which will be a link to the Python toolchain
# FIXME: Assumes that the entrypoint isn't relocated into the site-packages tree
exec "$(rlocation "{{ARG_VENV}}")"/bin/python {{INTERPRETER_FLAGS}} "$(rlocation {{ENTRYPOINT}})" "$@"
