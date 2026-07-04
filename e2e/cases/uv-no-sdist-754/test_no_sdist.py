import unittest

from bazel_tools.tools.python.runfiles import runfiles


class WhlInstallShapeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        r = runfiles.Create()
        path = r.Rlocation("_main/uv-no-sdist-754/pywin32_targets")
        with open(path) as f:
            cls.targets = {line.strip() for line in f if line.strip()}

    def _has_suffix(self, suffix):
        return any(t.endswith(suffix) for t in self.targets)

    def _has_substring(self, substring):
        return any(substring in t for t in self.targets)

    def test_whl_missing_default_present(self):
        self.assertTrue(self._has_suffix(":whl_missing"))

    def test_stale_no_sbuild_absent(self):
        self.assertFalse(self._has_suffix(":_no_sbuild"))

    def test_select_chain_terminates_at_whl_11(self):
        self.assertTrue(self._has_suffix(":whl_11"))

    def test_select_chain_does_not_overflow_to_whl_12(self):
        # whl_12 would mean the default leaked back onto the arms dict.
        self.assertFalse(self._has_suffix(":whl_12"))

    def test_windows_wheel_targets_present(self):
        self.assertTrue(self._has_substring("win_amd64"))
        self.assertTrue(self._has_substring("win32.whl"))


if __name__ == "__main__":
    unittest.main()
