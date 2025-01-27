import os
import pathlib
import unittest

import runfiles  # requirement("bazel-runfiles")

class RunfilesTest(unittest.TestCase):
    def test_runfiles(self) -> None:
        r = runfiles.Runfiles.Create()
        path = pathlib.Path(r.Rlocation(os.getenv("BAZEL_WORKSPACE")+"/py/tests/py-binary/test_data.txt"))
        self.assertEquals(path.read_text(), "42\n")

if __name__ == "__main__":
    unittest.main()
