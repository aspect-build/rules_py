#!/bin/sh

set -o errexit -o nounset

PYTHON_BIN="{{PYTHON_BIN}}"

# We need to ensure that we exec Python from within the venv path if set so that the correct
# exec and base prefixes are set.
if [ -z "${VIRTUAL_ENV:-}" ]; then
  exec "${PYTHON_BIN}" "$@"
else
  PYTHON_REAL="${VIRTUAL_ENV}/bin/python_real"
  ln -snf "${PYTHON_BIN}" "${PYTHON_REAL}"
  exec "${PYTHON_REAL}" "$@"
fi
