#!/usr/bin/env bash
# Hermetic container launcher for py_binary targets.
# Uses Bazel runfiles and direct PYTHONPATH injection.
# NO virtualenv is assumed or created at runtime.

set -o errexit -o nounset -o pipefail

# Initialize Bazel runfiles
{{BASH_RLOCATION_FN}}
runfiles_export_envvars

# Resolve the Python interpreter
PYTHON="{{ARG_PYTHON}}"
if [[ "{{RUNFILES_INTERPRETER}}" == "true" ]]; then
    PYTHON="$(rlocation "${PYTHON}")"
fi

# Resolve the entrypoint
ENTRYPOINT="$(rlocation {{ENTRYPOINT}})"

# Resolve the .pth file and construct PYTHONPATH
PTH_FILE="$(rlocation {{ARG_PTH_FILE}})"
PTH_DIR="$(dirname "${PTH_FILE}")"

_normalize_path() {
    local _path="$1"
    local _IFS="/"
    local -a _parts
    local -a _result=()
    read -ra _parts <<< "${_path}"
    for _part in "${_parts[@]}"; do
        if [[ -z "${_part}" || "${_part}" == "." ]]; then
            continue
        elif [[ "${_part}" == ".." ]]; then
            if [[ ${#_result[@]} -gt 0 && "${_result[-1]}" != ".." ]]; then
                unset '_result[-1]'
            else
                _result+=("..")
            fi
        else
            _result+=("${_part}")
        fi
    done
    local _out=""
    if [[ "${_path}" == /* ]]; then
        _out="/"
    fi
    _out="${_out}${_result[*]}"
    _out="${_out// /\/}"
    echo "${_out:-.}"
}

_EXTRA_PYTHONPATH=""
while IFS= read -r _line || [[ -n "${_line}" ]]; do
    case "${_line}" in
        ""|\#*|import*) continue ;;
    esac
    _abs_path="$(_normalize_path "${PTH_DIR}/${_line}")"
    if [[ -d "${_abs_path}" ]]; then
        if [[ -z "${_EXTRA_PYTHONPATH}" ]]; then
            _EXTRA_PYTHONPATH="${_abs_path}"
        else
            _EXTRA_PYTHONPATH="${_EXTRA_PYTHONPATH}:${_abs_path}"
        fi
    fi
done < "${PTH_FILE}"

if [[ -n "${_EXTRA_PYTHONPATH}" ]]; then
    export PYTHONPATH="${_EXTRA_PYTHONPATH}${PYTHONPATH:+:${PYTHONPATH}}"
fi

# Set runtime environment
{{PYTHON_ENV}}

# Direct exec
exec "${PYTHON}" {{INTERPRETER_FLAGS}} "${ENTRYPOINT}" "$@"
