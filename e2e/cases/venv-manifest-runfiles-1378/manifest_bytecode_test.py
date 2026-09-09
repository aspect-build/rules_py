"""A bytecode-mode unittest driver runs under manifest-only runfiles, with its
bytecode at the natural paths the manifest lists."""

import os
import subprocess
import sys

mode = os.environ["EXPECT_PYC"]
runfiles_dir = os.environ["RUNFILES_DIR"]
manifest = os.path.join(runfiles_dir, "MANIFEST")
package = "_main/venv-manifest-runfiles-1378/"
unittest = os.path.join(runfiles_dir, package + "manifest_unittest_" + mode)

with open(manifest, encoding="utf-8") as f:
    entries = {line.partition(" ")[0] for line in f}
source = package + "manifest_unittest_test.py"
if mode == "sourceless":
    assert source not in entries, "source shipped beside sourceless bytecode"
    assert package + "manifest_unittest_test.pyc" in entries, "no colocated bytecode in the manifest"
else:
    assert source in entries, "source missing under pycache"
    cache = package + "firstparty/__pycache__/greet."
    assert any(entry.startswith(cache) and entry.endswith(".pyc") for entry in entries), "no __pycache__ in the manifest"

# A decoy at the test's runfiles-relative path in the working directory must never be loaded.
decoy_cwd = os.path.join(os.environ["TEST_TMPDIR"], "decoy")
os.makedirs(os.path.join(decoy_cwd, "venv-manifest-runfiles-1378"), exist_ok=True)
with open(os.path.join(decoy_cwd, "venv-manifest-runfiles-1378", "manifest_unittest_test.py"), "w") as f:
    f.write("raise AssertionError('decoy source loaded from the working directory')\n")

env = {k: v for k, v in os.environ.items() if k != "RUNFILES_DIR"}
env["RUNFILES_MANIFEST_FILE"] = manifest
sys.exit(subprocess.run([unittest], cwd=decoy_cwd, env=env).returncode)
