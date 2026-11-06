"""The LCOV SF: fixup maps sources under a chdir back to their manifest paths.

Runfiles are real files rather than symlinks under remote execution, so a
source below the chdir stays below the CWD after coveragepy resolves it, and
coveragepy writes its SF: path relative to the CWD. This builds that layout
directly instead of relying on how the local runfiles tree is materialized.
"""

import os
import sys
import tempfile

import rules_py_launcher_env as launcher_env

root = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])
package = os.path.join(root, "pkg")
os.makedirs(package)
with open(os.path.join(package, "chdir_mod.py"), "w") as f:
    f.write("def absolute(a):\n    if a < 0:\n        return -a\n    return a\n")

manifest = os.path.join(root, "coverage_manifest.txt")
with open(manifest, "w") as f:
    f.write("pkg/chdir_mod.py\n")
output = os.path.join(root, "coverage.dat")
os.environ["COVERAGE_MANIFEST"] = manifest
os.environ["COVERAGE_OUTPUT_FILE"] = output

# Same order as pytest_main.py: record the runfiles root, chdir, then start.
os.chdir(package)
cov = launcher_env.start_coverage(root)
assert cov is not None, "coverage did not start"
sys.path.insert(0, package)
import chdir_mod  # noqa: E402

assert chdir_mod.absolute(-2) == 2
# A test that changes directory without restoring it must not break the mapping.
os.chdir(root)
launcher_env.write_lcov(cov)

with open(output) as f:
    source_files = [line.rstrip("\n") for line in f if line.startswith("SF:")]
assert source_files == ["SF:pkg/chdir_mod.py"], source_files
print("OK")
