"""The default python_interpreter_constraints must be stamped from the binary's
own interpreter version, not the pex rule's toolchain.

app_mismatch pins python_version 3.13 while this workspace's default is 3.11.
With the default constraint (`CPython=={major}.{minor}.*`) the PEX must advertise
3.13 — the interpreter it was actually built for — otherwise it would refuse to
run on its own target interpreter.
"""

import json
import os
import zipfile
from pathlib import Path

pex = (
    Path(os.environ["RUNFILES_DIR"])
    / "_main/pex-interpreter-exclusion/app_mismatch_constrained_pex.pex"
)
with zipfile.ZipFile(pex) as zf:
    info = json.loads(zf.read("PEX-INFO"))

assert info["interpreter_constraints"] == ["CPython==3.13.*"], info[
    "interpreter_constraints"
]
