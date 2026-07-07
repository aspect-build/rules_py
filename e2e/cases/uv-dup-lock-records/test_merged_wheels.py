import unittest

from bazel_tools.tools.python.runfiles import runfiles


class DuplicateLockRecordsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        r = runfiles.Create()
        path = r.Rlocation("_main/uv-dup-lock-records/markupsafe_targets")
        with open(path) as f:
            cls.targets = {line.strip() for line in f if line.strip()}

    def _has_substring(self, substring):
        return any(substring in t for t in self.targets)

    def test_first_record_wheels_present(self):
        self.assertTrue(self._has_substring("win_amd64"))

    def test_second_record_wheels_present(self):
        # Lost before the duplicate lock records were merged.
        self.assertTrue(self._has_substring("macosx_10_9_x86_64"))
        self.assertTrue(self._has_substring("macosx_11_0_arm64"))

    def test_third_record_wheels_present(self):
        # Lost before the duplicate lock records were merged.
        self.assertTrue(self._has_substring("manylinux_2_17_x86_64"))
        self.assertTrue(self._has_substring("manylinux_2_17_aarch64"))


if __name__ == "__main__":
    unittest.main()
