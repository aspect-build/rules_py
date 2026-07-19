import os
import zipfile
from pathlib import Path

# app_pex uses the default toolchain; app_mismatch_pex pins python_version 3.13
# (!= the workspace default) so both the same-version and cross-version
# interpreter-exclusion paths are covered.
PEXES = (
    "_main/pex-interpreter-exclusion/app_pex.pex",
    "_main/pex-interpreter-exclusion/app_mismatch_pex.pex",
)
INTERPRETER_REPO_MARKERS = (
    "aspect_rules_py++python_interpreters+",
    "aspect_rules_py~~python_interpreters~",
)

for rel in PEXES:
    pex = Path(os.environ["RUNFILES_DIR"]) / rel
    with zipfile.ZipFile(pex) as zf:
        leaked = [
            name
            for name in zf.namelist()
            if any(marker in name for marker in INTERPRETER_REPO_MARKERS)
        ]
    assert not leaked, (rel, leaked[:10])
