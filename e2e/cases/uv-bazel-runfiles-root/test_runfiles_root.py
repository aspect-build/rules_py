import os
from pathlib import Path

from runfiles import runfiles

runfiles_dir = os.environ["RUNFILES_DIR"]
assert runfiles._FindPythonRunfilesRoot() == runfiles_dir

r = runfiles.Create()
assert r is not None
path = r.Rlocation("_main/cases/uv-bazel-runfiles-root/runfiles_root_data.txt")
assert path is not None
assert Path(path).read_text() == "runfiles root data\n"
