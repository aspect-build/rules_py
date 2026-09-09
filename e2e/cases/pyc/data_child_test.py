"""A sourceless executable in `data` ships only its bytecode: the parent adds no
source files of its own beside the child's runfiles.
"""

import os
import subprocess
from pathlib import Path

root = Path(os.environ["RUNFILES_DIR"]) / "_main/pyc"
present = {p.name for p in root.iterdir() if p.name.startswith(("noop", "pex_lib"))}
assert present == {"noop.pyc", "pex_lib.pyc"}, present

subprocess.run([root / "data_child_bin"], check=True)
