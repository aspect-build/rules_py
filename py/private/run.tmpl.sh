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
    echo -n "${PWD%/}/${P}"
  fi
}

function python_location {
  local PYTHON="{{ARG_PYTHON}}"
  local RUNFILES_INTERPRETER="{{RUNFILES_INTERPRETER}}"

  if [[ "${RUNFILES_INTERPRETER}" == "true" ]]; then
    echo -n "$(alocation "$(rlocation ${PYTHON})")"
  else
    echo -n "${PYTHON}"
  fi
}

RUNFILES_DIR="${RUNFILES_DIR:-/opt}"
VENV_TOOL="$(rlocation {{VENV_TOOL}} || true)"
VIRTUAL_ENV="$(alocation "${RUNFILES_DIR}/{{ARG_VENV_NAME}}")"
export VIRTUAL_ENV

if [ -f "${VIRTUAL_ENV}/bin/python" ]; then
    :
else
    # Try to find a pre-materialized venv in runfiles (e.g. from py_venv_materialize)
    ALT_VENV=$(find -L "${RUNFILES_DIR}" -maxdepth 4 -type d -name "*.venv" 2>/dev/null | head -1)
    if [ -n "$ALT_VENV" ] && [ -f "$ALT_VENV/bin/python" ]; then
        VIRTUAL_ENV="$ALT_VENV"
        export VIRTUAL_ENV
    elif [ -n "$VENV_TOOL" ] && [ -f "$VENV_TOOL" ]; then
        "${VENV_TOOL}" \
            --location "${VIRTUAL_ENV}" \
            --python "$(python_location)" \
            --pth-file "$(rlocation {{ARG_PTH_FILE}})" \
            --collision-strategy "{{ARG_COLLISION_STRATEGY}}" \
            --venv-name "{{ARG_VENV_NAME}}"
    else
        echo "ERROR: No materialized venv found at ${VIRTUAL_ENV} and no venv tool available" >&2
        exit 1
    fi
fi

# If we found an alternative venv, use its site-packages with the original interpreter.
# We explicitly import sitecustomize.py because the Bazel-provided interpreter does
# not auto-load it from PYTHONPATH (it only loads from standard site-packages).
if [ "$VIRTUAL_ENV" != "$(alocation "${RUNFILES_DIR}/{{ARG_VENV_NAME}}")" ]; then
    PYTHON="$(python_location)"
    SITE_PACKAGES="$(find -L "$VIRTUAL_ENV" -type d -name site-packages | head -1)"
    ENTRYPOINT_RLOCATION="$(rlocation {{ENTRYPOINT}})"
    # Remove -I (isolated mode) because it implies -E which ignores PYTHONPATH.
    INTERPRETER_FLAGS="{{INTERPRETER_FLAGS}}"
    INTERPRETER_FLAGS=$(echo "$INTERPRETER_FLAGS" | sed 's/\-I//g' | xargs)
    exec "$PYTHON" $INTERPRETER_FLAGS -c "
import sys, os
_site_packages = '${SITE_PACKAGES}'
if _site_packages:
    sys.path[:0] = [_site_packages]
    # Process .pth files in site-packages (Python won't do it since
    # site-packages was added after site module initialization).
    for _f in os.listdir(_site_packages):
        if _f.endswith('.pth'):
            with open(os.path.join(_site_packages, _f)) as _pth:
                for _line in _pth:
                    _line = _line.strip()
                    if _line and not _line.startswith('#') and not _line.startswith('import'):
                        _path = os.path.normpath(os.path.join(_site_packages, _line))
                        if os.path.isdir(_path) and _path not in sys.path:
                            sys.path.append(_path)
    import sitecustomize
sys.argv[0] = '${ENTRYPOINT_RLOCATION}'
with open(sys.argv[0]) as _f:
    _code = compile(_f.read(), sys.argv[0], 'exec')
exec(_code)
" "$@"
fi

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