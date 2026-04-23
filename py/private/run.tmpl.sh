#!/usr/bin/env bash
# Launcher for py_binary targets.
#
# A real venv tree (pyvenv.cfg + bin/python symlink + lib/.../site-packages/<name>.pth)
# is materialised at build time by py_binary.bzl. All this script has to do
# is exec the venv's bin/python — Python's own startup reads pyvenv.cfg,
# sets sys.prefix to the venv, and site.main() processes the .pth file.
#
# We also prepend <venv>/bin/ to $PATH so wheel-declared console scripts
# (generated as wrapper files under <venv>/bin/<name> by py_binary.bzl)
# are discoverable to subprocess.run(["<name>", ...]) from user code.
#
# NB: we don't use a path from @bazel_tools//tools/sh:toolchain_type because that's configured for the exec
# configuration, while this script executes in the target configuration at runtime.

# This is a special comment for py_pex_binary to find the python entrypoint.
# __PEX_PY_BINARY_ENTRYPOINT__ {{ENTRYPOINT}}

{{BASH_RLOCATION_FN}}
runfiles_export_envvars

set -o errexit -o nounset -o pipefail

VENV_PYTHON="$(rlocation {{ARG_VENV_PYTHON}})"
VENV_BIN="$(dirname "${VENV_PYTHON}")"
export VIRTUAL_ENV="$(dirname "${VENV_BIN}")"
export PATH="${VENV_BIN}:${PATH-}"

# Set all the env vars here, just before we launch
{{PYTHON_ENV}}

exec "${VENV_PYTHON}" {{INTERPRETER_FLAGS}} "$(rlocation {{ENTRYPOINT}})" "$@"
