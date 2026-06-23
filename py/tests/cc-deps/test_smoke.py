import os
import subprocess
import sys
from pathlib import Path

import native_module
from python.runfiles import runfiles


assert native_module.answer() == 42

filename = "native_module.pyd" if os.name == "nt" else "native_module.so"
logical = "_main/py/tests/cc-deps/" + filename
runfiles = runfiles.Create()
assert runfiles is not None
extension = runfiles.Rlocation(logical)
assert extension is not None
manifest = Path(os.environ["TEST_TMPDIR"]) / "native-module-manifest"
manifest.write_text(f"{logical} {extension}\n")
env = dict(os.environ)
env["RUNFILES_MANIFEST_FILE"] = str(manifest)
env["RUNFILES_MANIFEST_ONLY"] = "1"
env.pop("RUNFILES_DIR", None)
env.pop("JAVA_RUNFILES", None)
subprocess.run(
    [
        sys.executable,
        "-I",
        "-c",
        "import native_module; assert native_module.answer() == 42",
    ],
    check=True,
    env=env,
)
