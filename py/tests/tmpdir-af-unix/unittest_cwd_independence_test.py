"""A unittest binary runs its packaged tests from any working directory."""

import os
import subprocess
import tempfile

decoy_dir = tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"])
decoy = os.path.join(decoy_dir, "py", "tests", "tmpdir-af-unix", "unittest_af_unix_test.py")
os.makedirs(os.path.dirname(decoy))
with open(decoy, "w") as f:
    f.write("import unittest\n\n\nclass Decoy(unittest.TestCase):\n    def test_decoy(self):\n        self.fail('decoy source ran')\n")

binary = os.path.join(os.environ["RUNFILES_DIR"], "_main", os.environ["UNITTEST_BIN"])
result = subprocess.run([binary], cwd=decoy_dir, capture_output=True, text=True)
assert result.returncode == 0, result.stdout + result.stderr
assert "decoy" not in result.stdout + result.stderr, result.stdout + result.stderr
print("OK")
