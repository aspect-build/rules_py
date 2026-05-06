#!/usr/bin/env bash
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
