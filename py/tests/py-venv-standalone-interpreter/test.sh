#!/usr/bin/env sh

set -eu

ROOT=$(CDPATH= cd "${0%/*}" && pwd -P)

unset JAVA_RUNFILES RUNFILES_DIR RUNFILES_MANIFEST_FILE
PYTHONHOME=/must-not-reach-the-venv-interpreter
export PYTHONHOME
cd "${TEST_TMPDIR}"

for venv in .ex.venv .ex_3_12.venv; do
    PYTHON=${ROOT}/${venv}/bin/python
    "${PYTHON}" --help >/dev/null 2>&1
    PYTHON="${PYTHON}" "${PYTHON}" -c '
import os
import sys
from ex import hello

assert hello() == "Hello, world!"
assert os.path.samefile(os.getcwd(), os.environ["TEST_TMPDIR"])
assert os.path.samefile(sys.executable, os.environ["PYTHON"]), sys.executable
assert os.path.samefile(
    sys.prefix,
    os.path.dirname(os.path.dirname(sys.executable)),
), sys.prefix
assert sys.base_prefix != "/install", sys.base_prefix
assert "PYTHONHOME" not in os.environ
'

    "${ROOT}/${venv}/bin/python3" -c 'from ex import hello; assert hello() == "Hello, world!"'

    "${PYTHON}" -c 'from pathlib import Path; Path("cwd_module.py").write_text("VALUE = 1\n")'
    "${PYTHON}" -c 'from pathlib import Path; Path("relative-pythonpath").mkdir(exist_ok=True); Path("relative-pythonpath/path_marker.py").write_text("VALUE = 1\n")'
    PYTHONPATH=relative-pythonpath "${PYTHON}" -c 'import os, path_marker; assert path_marker.VALUE == 1; assert os.environ["PYTHONPATH"] == "relative-pythonpath"'
    PYTHONPATH=relative-pythonpath "${PYTHON}" -m path_marker
    "${PYTHON}" -m cwd_module
    "${PYTHON}" -E -m cwd_module
    if "${PYTHON}" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
        if "${PYTHON}" -P -m cwd_module >/dev/null 2>&1; then
            printf '%s\n' "-P -m unexpectedly imported from the caller cwd" >&2
            exit 1
        fi
        if PYTHONSAFEPATH=1 "${PYTHON}" -m cwd_module >/dev/null 2>&1; then
            printf '%s\n' "PYTHONSAFEPATH unexpectedly imported from the caller cwd" >&2
            exit 1
        fi
        PYTHONPATH= "${PYTHON}" -P -c \
            'import os, sys; assert os.getcwd() not in sys.path'
    else
        PYTHONSAFEPATH=1 "${PYTHON}" -m cwd_module
    fi
    "${PYTHON}" -I -S -c 'import sys; assert sys.prefix == sys.base_prefix'
    "${PYTHON}" -E -S -c 'import sys; assert sys.prefix == sys.base_prefix'

    NESTED_VENV=${TEST_TMPDIR}/${venv}.nested
    "${PYTHON}" -m venv --without-pip "${NESTED_VENV}"
    PYTHONHOME= "${NESTED_VENV}/bin/python" -c \
        'import sys; assert sys.prefix != sys.base_prefix'

    VENV_LINK=${TEST_TMPDIR}/${venv}.link
    "${PYTHON}" -c 'import os, sys; os.symlink(sys.argv[1], sys.argv[2])' \
        "${ROOT}/${venv}" "${VENV_LINK}"
    "${VENV_LINK}/bin/python" -c 'from ex import hello; assert hello() == "Hello, world!"'

    # Model a runfiles tree that materializes the venv but not the external
    # interpreter tree. A child script must still find Python through PATH.
    STAGED_VENV=${TEST_TMPDIR}/${venv}.staged
    mkdir -p "${STAGED_VENV}/bin"
    cp "${PYTHON}" "${STAGED_VENV}/bin/python"
    ln -s python "${STAGED_VENV}/bin/python3"
    ln -s "${ROOT}/${venv}.runtime-python" "${STAGED_VENV}.runtime-python"
    printf '%s\n' '#!/usr/bin/env python3' \
        'from ex import hello' \
        'assert hello() == "Hello, world!"' >"${STAGED_VENV}/env-python"
    chmod +x "${STAGED_VENV}/env-python"
    RUNFILES_DIR=${TEST_SRCDIR} PATH="${STAGED_VENV}/bin:${PATH}" \
        "${STAGED_VENV}/env-python"
    RUNFILES_DIR=${TEST_SRCDIR} PATH="${STAGED_VENV}/bin:${PATH}" \
        PYTHONPATH=relative-pythonpath "${STAGED_VENV}/bin/python" -m path_marker
done
