#!/usr/bin/env bash

set -ex

ROOT=$(CDPATH= cd "${0%/*}" && pwd -P)
LINK_DIR=${TEST_TMPDIR}/linked
mkdir "${LINK_DIR}"
BAZEL_TARGET=//venv-bin-scripts-423:exposed_bin.venv_link \
    BAZEL_WORKSPACE=_main \
    BUILD_WORKING_DIRECTORY=${LINK_DIR} \
    VIRTUAL_ENV=venv-bin-scripts-423/.exposed_bin.venv \
    "${ROOT}/exposed_bin.venv_link" --name=exposed.venv
LINKED_VENV=${LINK_DIR}/exposed.venv/_main/venv-bin-scripts-423/.exposed_bin.venv
test -f "${LINKED_VENV}/bin/activate"
test -x "${LINKED_VENV}/bin/roll"

. "${LINKED_VENV}/bin/activate"
test "${VIRTUAL_ENV}" = "${LINKED_VENV}"
test "$(command -v python)" = "${LINKED_VENV}/bin/python"
test "$(command -v roll)" = "${LINKED_VENV}/bin/roll"
roll 1d6 | grep -E '^\[[1-6]\]$'
deactivate
test -z "${VIRTUAL_ENV:-}"

cd "${LINK_DIR}"
. exposed.venv/_main/venv-bin-scripts-423/.exposed_bin.venv/bin/activate
test "${VIRTUAL_ENV}" = "${LINKED_VENV}"
cd "${TEST_TMPDIR}"
test "$(command -v python)" = "${LINKED_VENV}/bin/python"
roll 1d6 | grep -E '^\[[1-6]\]$'
deactivate
