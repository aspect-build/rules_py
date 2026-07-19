"""py_pex_binary must package a source-built (sdist) wheel.

cowsay 6.0 is forced to build from source (no-binary-package), so its
PyWheelsInfo record carries an install_tree but empty analysis-time metadata.
The refactored py_pex_binary discovers deps through PyWheelsInfo, so it must
still emit cowsay as a `--dependency` even without that metadata, while keeping
the interpreter and venv plumbing out.
"""

import os
import zipfile
from pathlib import Path

pex = Path(os.environ["RUNFILES_DIR"]) / "_main/uv-sdist-fallback/sdist_pex.pex"
with zipfile.ZipFile(pex) as zf:
    names = zf.namelist()

assert any(
    n.endswith("cowsay/__init__.py") for n in names
), "source-built cowsay missing from pex: {}".format(names[:20])

interpreter = [n for n in names if "python_interpreters" in n]
assert not interpreter, interpreter[:10]

venv_plumbing = [
    n for n in names if n.endswith("pyvenv.cfg") or n.endswith(".pth") or ".venv/" in n
]
assert not venv_plumbing, venv_plumbing
