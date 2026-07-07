import os
import zipfile
from pathlib import Path

PEX = "_main/pex-interpreter-exclusion/app_pex.pex"
INTERPRETER_REPO_MARKERS = (
    "aspect_rules_py++python_interpreters+",
    "aspect_rules_py~~python_interpreters~",
)

pex = Path(os.environ["RUNFILES_DIR"]) / PEX
with zipfile.ZipFile(pex) as zf:
    leaked = [
        name
        for name in zf.namelist()
        if any(marker in name for marker in INTERPRETER_REPO_MARKERS)
    ]

assert not leaked, leaked[:10]
