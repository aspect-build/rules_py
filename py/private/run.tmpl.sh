#!/usr/bin/env bash
# NB: we don't use a path from @bazel_tools//tools/sh:toolchain_type because that's configured for the exec
# configuration, while this script executes in the target configuration at runtime.

# This is a special comment for py_pex_binary to find the python entrypoint.
# __PEX_PY_BINARY_ENTRYPOINT__ {{ENTRYPOINT}}

{{BASH_RLOCATION_FN}}
runfiles_export_envvars

set -o errexit -o nounset -o pipefail

PWD="$(pwd)"

# Returns an absolute path to the given location if the path is relative, otherwise return
# the path unchanged.
function alocation {
  local P=$1
  if [[ "${P:0:1}" == "/" ]]; then
    echo -n "${P}"
  else
    echo -n "${PWD}/${P}"
  fi
}

function python_location {
  local PYTHON="{{ARG_PYTHON}}"
  local RUNFILES_INTERPRETER="{{RUNFILES_INTERPRETER}}"

  if [[ "${RUNFILES_INTERPRETER}" == "true" ]]; then
    echo -n "$(alocation $(rlocation ${PYTHON}))"
  else
    echo -n "${PYTHON}"
  fi
}

VENV_TOOL="$(rlocation {{VENV_TOOL}})"
VIRTUAL_ENV="$(alocation "${RUNFILES_DIR}/{{ARG_VENV_NAME}}")"
export VIRTUAL_ENV

"${VENV_TOOL}" \
    --location "${VIRTUAL_ENV}" \
    --python "$(python_location)" \
    --python-version "{{ARG_VENV_PYTHON_VERSION}}" \
    --pth-file "$(rlocation {{ARG_PTH_FILE}})"

PATH="${VIRTUAL_ENV}/bin:${PATH}"
export PATH

# Set all the env vars here, just before we launch
{{PYTHON_ENV}}

# This should detect bash and zsh, which have a hash command that must
# be called to get it to forget past commands.  Without forgetting
# past commands the $PATH changes we made may not be respected
if [ -n "${BASH:-}" -o -n "${ZSH_VERSION:-}" ] ; then
    hash -r 2> /dev/null
fi

exec "{{EXEC_PYTHON_BIN}}" {{INTERPRETER_FLAGS}} "$(rlocation {{ENTRYPOINT}})" "$@"