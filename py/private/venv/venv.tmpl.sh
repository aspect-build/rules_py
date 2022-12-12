#!{{BASH_BIN}}

USE_MANIFEST_PATH={{USE_MANIFEST_PATH}}

if [ "$USE_MANIFEST_PATH" = true ]; then
  {{BASH_RLOCATION_FN}}
  runfiles_export_envvars
fi

set -o errexit -o nounset -o pipefail

export BAZEL_WORKSPACE_NAME="{{BAZEL_WORKSPACE_NAME}}"

function maybe_rlocation() {
  local P=$1
  if [ "$USE_MANIFEST_PATH" = false ]; then
    echo "${P}"
  else
    local MP
    MP=$(rlocation "${P}")
    echo "${MP}"
  fi
}

# Resolved from the py_interpreter via PyInterpreterInfo.
PYTHON_LOCATION="{{PYTHON_INTERPRETER_PATH}}"
PYTHON="${PYTHON_LOCATION} {{INTERPRETER_FLAGS}}"
REAL_PYTHON_LOCATION=$(${PYTHON} -c 'import sys; import os; print(os.path.realpath(sys.executable))')
PYTHON_SITE_PACKAGES=$(${PYTHON} -c 'import site; print(site.getsitepackages()[0])')
PYTHON_BIN_DIR=$(${PYTHON} -c 'import sys; import os; print(os.path.dirname(sys.executable))')
PIP_LOCATION="${PYTHON_BIN_DIR}/pip"
PTH_FILE=$(maybe_rlocation "{{PTH_FILE}}")
WHL_REQUIREMENTS_FILE=$(maybe_rlocation "{{WHL_REQUIREMENTS_FILE}}")

# Convenience vars for the Python virtual env that's created.
VENV_LOCATION="{{VENV_LOCATION}}"
VBIN_LOCATION="${VENV_LOCATION}/bin"
VPIP_LOCATION="${VBIN_LOCATION}/pip"
VPYTHON="${VBIN_LOCATION}/python3 {{INTERPRETER_FLAGS}}"
VPIP="${VPYTHON} -m pip"

# Create a virtual env to run inside. This allows us to not have to manipulate the PYTHON_PATH to find external
# dependencies.
# We can also now specify the `-I` (isolated) flag to Python, stopping Python from adding the script path to sys.path[0]
# which we have no control over otherwise.
# This does however have some side effects as now all other PYTHON* env vars are ignored.

# The venv is intentionally created without pip, as when the venv is created with pip, `ensurepip` is used which will
# use the bundled version of pip, which does not match the version of pip bundled with the interpreter distro.
# So we symlink in this ourselves.
VENV_FLAGS=(
  "--without-pip"
  "--clear"
  # Setting copies seems to break as venv doesn't copy libs when being forced to do copying rather than symlinks,
  # so we do it manually before starting the binary
)

${PYTHON} -m venv "${VENV_LOCATION}" "${VENV_FLAGS[@]}"

# Activate the venv, disable changing the prompt
export VIRTUAL_ENV_DISABLE_PROMPT=1
. "${VBIN_LOCATION}/activate"
unset VIRTUAL_ENV_DISABLE_PROMPT

# Now symlink in pip from the toolchain
# Python venv will also link `pip3.x`, but this seems unnecessary for this use
ln -snf "${PIP_LOCATION}" "${VPIP_LOCATION}"

# Need to symlink in the pip site-packages folder not just the binary.
# Ask Python where the site-packages folder is and symlink the pip package in from the toolchain
VENV_SITE_PACKAGES=$(${VPYTHON} -c 'import site; print(site.getsitepackages()[0])')
ln -snf "${PYTHON_SITE_PACKAGES}/pip" "${VENV_SITE_PACKAGES}/pip"

# If the incoming requirements file has setuptools the skip creating a symlink to our own as they will cause
# error when installing.
set +o errexit
$(grep --quiet "setuptools-[0-9]*.*.whl" "${WHL_REQUIREMENTS_FILE}")
HAS_SETUPTOOLS=$?
set -o errexit

if [ ${HAS_SETUPTOOLS} -gt 0 ]; then
  ln -snf "${PYTHON_SITE_PACKAGES}/_distutils_hack" "${VENV_SITE_PACKAGES}/_distutils_hack"

  ln -snf "${PYTHON_SITE_PACKAGES}/setuptools" "${VENV_SITE_PACKAGES}/setuptools"
fi

INSTALL_WHEELS={{INSTALL_WHEELS}}
if [ "$INSTALL_WHEELS" = true ]; then
  # Call to pip to "install" our dependencies. The `find-links` section in the config points to the external downloaded wheels,
  # while `--no-index` ensures we don't reach out to PyPi
  # We may hit command line length limits if passing a large number of find-links flags, so set them on the PIP_FIND_LINKS env var
  PIP_FIND_LINKS=$(tr '\n' ' ' < "${WHL_REQUIREMENTS_FILE}")
  export PIP_FIND_LINKS

  PIP_FLAGS=(
    "--quiet"
    "--no-compile"
    "--require-virtualenv"
    "--no-input"
    "--no-cache-dir"
    "--disable-pip-version-check"
    "--no-python-version-warning"
    "--only-binary=:all:"
    "--no-dependencies"
    "--no-index"
  )

  ${VPIP} install "${PIP_FLAGS[@]}" -r "${WHL_REQUIREMENTS_FILE}"

  unset PIP_FIND_LINKS
fi

# Create the site-packages pth file containing all our first party dependency paths. These are from all direct and transitive
# py_library rules.
# The .pth file adds to the interpreters sys.path, without having to set `PYTHONPATH`. This allows us to still
# run with the interpreter with the `-I` flag. This stops some import mechanisms breaking out the sandbox by using
# relative imports.
cat "${PTH_FILE}" > "${VENV_SITE_PACKAGES}/first_party.pth"

# Remove the cfg file as it contains absolute paths.
# The entrypoint script for py_binary and py_test will create a new one.
# For local venvs, we'll create a new one below.
PYVENV_CFG="${VENV_LOCATION}/pyvenv.cfg"
rm  "${PYVENV_CFG}"

if [ "$USE_MANIFEST_PATH" = false ]; then
  # Tear down the symlinks created above as these won't be able to be resolved by bazel when validating the TreeArtifact.
  VENV_SYMLINKS=($(find "${VENV_LOCATION}" -type l))
  for symlink in "${VENV_SYMLINKS[@]}"; do
    rm "${symlink}"
  done
fi

if [ "$USE_MANIFEST_PATH" = true ]; then
  # If we are in a 'bazel run' then remove the symlinks to the execroot Python and replace them with a link to external
  rm ${VBIN_LOCATION}/python*

  ln -snf "${REAL_PYTHON_LOCATION}" "${VBIN_LOCATION}/python"
  ln -snf "${VBIN_LOCATION}/python" "${VBIN_LOCATION}/python3"

  PYTHON_SYMLINK_VERSION_SUFFIX=$(${PYTHON} -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  ln -snf "${VBIN_LOCATION}/python" "${VBIN_LOCATION}/python${PYTHON_SYMLINK_VERSION_SUFFIX}"

  PYTHON_VERSION=$(${PYTHON} -c 'import platform; print(platform.python_version())')
  echo "home = ${VBIN_LOCATION}" > "${PYVENV_CFG}"
  echo "include-system-site-packages = false" >> "${PYVENV_CFG}"
  echo "version = ${PYTHON_VERSION}" >> "${PYVENV_CFG}"

  chmod +x "${VBIN_LOCATION}/activate"
  chmod +x "${VBIN_LOCATION}/activate.csh"
  chmod +x "${VBIN_LOCATION}/activate.fish"
fi
