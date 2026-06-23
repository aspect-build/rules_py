#!/usr/bin/env sh

set -ex

ROOT=$(CDPATH= cd "${0%/*}" && pwd -P)

"$ROOT"/.ex.venv/bin/python --help >/dev/null 2>&1

if [ "Hello, world!" != "$("${ROOT}/.ex.venv/bin/python" -c 'from ex import hello; print(hello())')" ]; then
    exit 1
fi

LINK_DIR=${TEST_TMPDIR}/linked
mkdir "${LINK_DIR}"
BAZEL_TARGET=//py/tests/py-venv-standalone-interpreter:ex.venv_link \
    BAZEL_WORKSPACE=_main \
    BUILD_WORKING_DIRECTORY=${LINK_DIR} \
    VIRTUAL_ENV=py/tests/py-venv-standalone-interpreter/.ex.venv \
    "${ROOT}/ex.venv_link" --name=ex.venv
cd "${LINK_DIR}"
LINKED_VENV=${LINK_DIR}/ex.venv/_main/py/tests/py-venv-standalone-interpreter/.ex.venv
test -L "${LINK_DIR}/ex.venv"
test -d "${LINKED_VENV}"
"${LINKED_VENV}/bin/python" -c \
    'import cowsay, sys; from ex import hello; assert hello() == "Hello, world!"; assert sys.prefix != sys.base_prefix'
