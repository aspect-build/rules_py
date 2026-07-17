import unittest

from bazel_tools.tools.python.runfiles import runfiles


class WhlInstallShapeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        r = runfiles.Create()
        path = r.Rlocation("_main/uv-no-sdist-754/pywin32_targets")
        with open(path) as f:
            cls.targets = {line.strip() for line in f if line.strip()}
        manifest = r.Rlocation("_main/uv-no-sdist-754/gazelle_manifest.yaml")
        with open(manifest) as f:
            cls.manifest = f.read()

    def _has_suffix(self, suffix: str) -> bool:
        return any(t.endswith(suffix) for t in self.targets)

    def _has_substring(self, substring: str) -> bool:
        return any(substring in t for t in self.targets)

    def test_whl_missing_default_present(self) -> None:
        self.assertTrue(self._has_suffix(":whl_missing"))

    def test_stale_no_sbuild_absent(self) -> None:
        self.assertFalse(self._has_suffix(":_no_sbuild"))

    def test_select_chain_terminates_at_whl_11(self) -> None:
        self.assertTrue(self._has_suffix(":whl_11"))

    def test_select_chain_does_not_overflow_to_whl_12(self) -> None:
        # whl_12 would mean the default leaked back onto the arms dict.
        self.assertFalse(self._has_suffix(":whl_12"))

    def test_windows_wheel_targets_present(self) -> None:
        self.assertTrue(self._has_substring("win_amd64"))
        self.assertTrue(self._has_substring("win32.whl"))

    def test_gazelle_indexes_windows_modules_without_metadata(self):
        self.assertIn("    win32: pywin32\n", self.manifest)
        self.assertIn("    win32com: pywin32\n", self.manifest)


if __name__ == "__main__":
    unittest.main()
