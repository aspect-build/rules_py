#!/usr/bin/env bash
# Launcher for py_binary targets.
# Uses Bazel runfiles and direct PYTHONPATH injection.
# NO virtualenv materialization or mutation at runtime.

{{BASH_RLOCATION_FN}}
runfiles_export_envvars

set -o errexit -o nounset -o pipefail

# Resolve the Python interpreter path
PYTHON="{{ARG_PYTHON}}"
if [[ "{{RUNFILES_INTERPRETER}}" == "true" ]]; then
    PYTHON="$(rlocation "${PYTHON}")"
fi

# Resolve the entrypoint script
ENTRYPOINT="$(rlocation {{ENTRYPOINT}})"

# Resolve the .pth file
PTH_FILE="$(rlocation {{ARG_PTH_FILE}})"

# Ensure RUNFILES_DIR is exported (critical for containers)
export RUNFILES_DIR="${RUNFILES_DIR:-${0}.runfiles}"

_EXTRA_PYTHONPATH="${RUNFILES_DIR}"

while IFS= read -r _line || [[ -n "${_line}" ]]; do
    # Skip empty lines, comments, and Python import directives
    case "${_line}" in
        ""|\#*|import*) continue ;;
    esac

    # The .pth file now contains raw paths relative to RUNFILES_DIR
    _abs_path="${RUNFILES_DIR}/${_line}"

    if [[ -d "${_abs_path}" ]]; then
        _EXTRA_PYTHONPATH="${_EXTRA_PYTHONPATH}:${_abs_path}"
    fi
done < "${PTH_FILE}"

export PYTHONPATH="${_EXTRA_PYTHONPATH}${PYTHONPATH:+:${PYTHONPATH}}"

# Set Bazel environment variables
{{PYTHON_ENV}}

# Direct exec of the interpreter with the entrypoint
exec "${PYTHON}" {{INTERPRETER_FLAGS}} "${ENTRYPOINT}" "$@"