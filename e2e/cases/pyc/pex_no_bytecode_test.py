"""A PEX ships sources only: the PEX edge resets the pyc flag, and a binary
pinned to pyc keeps its __pycache__ out of the archive."""

import os
import zipfile
from pathlib import Path

for pex in ("noop_pex.pex", "pyc_noop_pex.pex"):
    with zipfile.ZipFile(Path(os.environ["RUNFILES_DIR"]) / "_main/pyc" / pex) as zf:
        names = zf.namelist()
    assert any(name.endswith("noop.py") for name in names), (pex, names[:10])
    assert not any(name.endswith(".pyc") for name in names), (pex, names[:10])

with zipfile.ZipFile(Path(os.environ["RUNFILES_DIR"]) / "_main/pyc/pyc_noop_pex.pex") as zf:
    assert any(name.endswith("pex_lib.py") for name in zf.namelist())

with zipfile.ZipFile(Path(os.environ["RUNFILES_DIR"]) / "_main/pyc/data_pyc_pex.pex") as zf:
    names = [name for name in zf.namelist() if name.startswith("_main/")]
assert "_main/pyc/data_fixture.pyc" in names, names
assert not any(name.endswith("noop.pyc") for name in names), names
