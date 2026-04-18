#!/usr/bin/env bash
# Container-specific launcher for py_binary targets.
# This launcher assumes the venv is pre-created during the build process.

set -o errexit -o nounset -o pipefail

# Determine the runfiles directory
RUNFILES_DIR=""
if [[ -n "${RUNFILES_DIR:-}" ]]; then
    RUNFILES_DIR="$RUNFILES_DIR"
elif [[ -n "${RUNFILES_MANIFEST_FILE:-}" ]]; then
    RUNFILES_DIR="${RUNFILES_MANIFEST_FILE%.manifest}"
elif [[ -d "$0.runfiles" ]]; then
    RUNFILES_DIR="$0.runfiles"
else
    RUNFILES_DIR="${0}.runfiles"
fi

# In containers, the venv is at a known location (set during build)
VENV_PATH="{{VENV_PATH}}"

# Verify the venv exists (it was created during build)
if [[ ! -d "$VENV_PATH" ]]; then
    echo "ERROR: Pre-built venv not found at $VENV_PATH" >&2
    echo "The container image may be corrupted." >&2
    exit 1
fi

# Find the Python interpreter in the venv
PYTHON="${VENV_PATH}/bin/{{EXEC_PYTHON_BIN}}"
if [[ ! -x "$PYTHON" ]]; then
    # Fallback to python3
    PYTHON="${VENV_PATH}/bin/python3"
fi

if [[ ! -x "$PYTHON" ]]; then
    echo "ERROR: Python interpreter not found in venv at $VENV_PATH/bin/" >&2
    exit 1
fi

# Set environment
export VIRTUAL_ENV="$VENV_PATH"
export PATH="${VENV_PATH}/bin:${PATH}"

# Set Bazel environment variables
{{PYTHON_ENV}}

# Run the actual Python entry point
exec "$PYTHON" -m {{ENTRYPOINT}} "$@"
