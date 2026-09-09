"""The PEX edge resets the pyc flag, so a bytecode-mode build ships no .pyc."""

import os
import zipfile
from pathlib import Path

pex = Path(os.environ["RUNFILES_DIR"]) / "_main/pyc/noop_pex.pex"
with zipfile.ZipFile(pex) as zf:
    names = zf.namelist()
assert any(name.endswith("noop.py") for name in names), names[:10]
assert not any(name.endswith(".pyc") for name in names), names[:10]
