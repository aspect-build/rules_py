"""#1394 via the sdist route: the mismatched wheel is never read.

`[tool.uv] no-binary-package` empties the package's wheel list, so `whl_dist`
never runs and the `InquirerPy-0.3.4-py3-none-any.whl` recorded in the lock is
inert. What installs is a wheel rules_py built from the sdist, whose filename
and `.dist-info` are both spelled the way the backend escapes them.

That the lock still records the mismatched wheel is guarded once for every
scenario by //uv-dist-info-case-1394:lock_fixtures_test.
"""

import unittest
from pathlib import Path

import InquirerPy
from InquirerPy import inquirer


class NoBinaryTest(unittest.TestCase):
    def test_source_built_package_installed(self) -> None:
        site_packages = Path(InquirerPy.__file__).parent.parent
        self.assertIsNotNone(inquirer.text)
        self.assertTrue((site_packages / "InquirerPy").is_dir())


if __name__ == "__main__":
    unittest.main()
