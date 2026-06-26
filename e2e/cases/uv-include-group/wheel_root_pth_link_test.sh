#!/usr/bin/env sh

set -ex

ROOT=$(CDPATH= cd "${0%/*}" && pwd -P)
LINK_DIR=${TEST_TMPDIR}/linked
mkdir "${LINK_DIR}"
BAZEL_TARGET=//cases/uv-include-group:wheel_root_pth_test.venv_link \
    BAZEL_WORKSPACE=_main \
    BUILD_WORKING_DIRECTORY=${LINK_DIR} \
    VIRTUAL_ENV=cases/uv-include-group/.wheel_root_pth_test.venv \
    "${ROOT}/wheel_root_pth_test.venv_link" --name=wheel-root-pth.venv
LINKED_VENV=${LINK_DIR}/wheel-root-pth.venv/_main/cases/uv-include-group/.wheel_root_pth_test.venv
test -L "${LINK_DIR}/wheel-root-pth.venv"
test -d "${LINKED_VENV}"
"${LINKED_VENV}/bin/python" \
    "${ROOT}/wheel_root_pth_test.py"
