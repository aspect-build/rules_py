#!{{BASH_BIN}}

{{BASH_RLOCATION_FN}}

runfiles_export_envvars

set -o errexit -o nounset -o pipefail

PWD=$(pwd)

forget_past_and_set_path () {
    # This should detect bash and zsh, which have a hash command that must
    # be called to get it to forget past commands.  Without forgetting
    # past commands the $PATH changes we made may not be respected
    if [ -n "${BASH:-}" -o -n "${ZSH_VERSION:-}" ] ; then
        hash -r 2> /dev/null
    fi
}

activate_venv () {
  local VENV_LOC=$1

  # Unset the VIRTUAL_ENV env var if one is set
  unset VIRTUAL_ENV
  VIRTUAL_ENV="${VENV_LOC}"
  export VIRTUAL_ENV

  _OLD_PATH="$PATH"
  PATH="${VIRTUAL_ENV}/bin:$PATH"
  export PATH

  # unset PYTHONHOME if set
  # this will fail if PYTHONHOME is set to the empty string (which is bad anyway)
  # could use `if (set -u; : $PYTHONHOME) ;` in bash
  if [ -n "${PYTHONHOME:-}" ] ; then
      _OLD_PYTHONHOME="${PYTHONHOME:-}"
      unset PYTHONHOME
  fi

  forget_past_and_set_path
}

deactivate_venv () {
    # reset old environment variables
    if [ -n "${_OLD_PATH:-}" ] ; then
        PATH="${_OLD_PATH:-}"
        export PATH
        unset _OLD_PATH
    fi

    if [ -n "${_OLD_PYTHONHOME:-}" ] ; then
        PYTHONHOME="${_OLD_PYTHONHOME:-}"
        export PYTHONHOME
        unset _OLD_PYTHONHOME
    fi

    forget_past_and_set_path

    unset VIRTUAL_ENV
}

# Returns an absolute path to the given location if the path is relative, otherwise return
# the path unchanged.
function alocation {
  local P=$1
  if [[ "${P:0:1}" == "/" ]]; then
    echo "${P}"
  else
    echo "${PWD}/${P}"
  fi
}

PYTHON_LOCATION="$(alocation $(rlocation {{PYTHON_INTERPRETER_PATH}}))"
PYTHON="${PYTHON_LOCATION} {{INTERPRETER_FLAGS}}"
PYTHON_VERSION=$(${PYTHON} -c 'import platform; print(platform.python_version())')
PYTHON_BIN_DIR=$(dirname "${PYTHON_LOCATION}")
PIP_LOCATION="${PYTHON_BIN_DIR}/pip"
ENTRYPOINT="$(rlocation {{BINARY_ENTRY_POINT}})"

# Convenience vars for the Python virtual env that's created.
VENV_SOURCE="$(alocation $(rlocation {{VENV_SOURCE}}))"
VENV_LOCATION="$(alocation ${RUNFILES_DIR}/{{VENV_NAME}})"
VBIN_LOCATION="${VENV_LOCATION}/bin"
VPYTHON="${VBIN_LOCATION}/python3 {{INTERPRETER_FLAGS}}"

mkdir "${VENV_LOCATION}" 2>/dev/null || true
ln -snf "${VENV_SOURCE}/include" "${VENV_LOCATION}/include"
ln -snf "${VENV_SOURCE}/lib" "${VENV_LOCATION}/lib"

mkdir "${VBIN_LOCATION}" 2>/dev/null || true
ln -snf ${VENV_SOURCE}/bin/* "${VBIN_LOCATION}/"
ln -snf "${PYTHON_LOCATION}" "${VBIN_LOCATION}/python3"
ln -snf "${VBIN_LOCATION}/python3" "${VBIN_LOCATION}/python"

echo "home = ${VBIN_LOCATION}" > "${VENV_LOCATION}/pyvenv.cfg"
echo "include-system-site-packages = false" >> "${VENV_LOCATION}/pyvenv.cfg"
echo "version = ${PYTHON_VERSION}" >> "${VENV_LOCATION}/pyvenv.cfg"

activate_venv "${VENV_LOCATION}"

# Set all the env vars here, just before we launch
{{PYTHON_ENV}}

# We can stop here an not run the py_binary / py_test entrypoint and just create the venv.
# This can be useful for editor support.
RUN_BINARY_ENTRY_POINT={{RUN_BINARY_ENTRY_POINT}}
if [ "$RUN_BINARY_ENTRY_POINT" = true ]; then
  # Finally, launch the entrypoint
  ${VPYTHON} "${ENTRYPOINT}" -- "$@"
fi

deactivate_venv

# Unset any set env vars
{{PYTHON_ENV_UNSET}}
