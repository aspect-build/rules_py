#!{{SHELL_BIN}}

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

VENV_TOOL="$(rlocation {{VENV_TOOL}})"
VENV_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
VIRTUAL_ENV="$(alocation "${VENV_ROOT}/{{ARG_VENV_LOCATION}}")"

"${VENV_TOOL}" \
    --location "${VIRTUAL_ENV}" \
    --python "$(alocation $(rlocation {{ARG_PYTHON}}))" \
    --python-version "{{ARG_VENV_PYTHON_VERSION}}" \
    --pth-file "$(rlocation {{ARG_PTH_FILE}})" \
    --pth-entry-prefix "${RUNFILES_DIR}"
