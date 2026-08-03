"""#1394 via the override route: the mismatched wheel is replaced wholesale.

`uv.override_package(target = ...)` substitutes a Bazel target for the locked
package, so the `InquirerPy-0.3.4-py3-none-any.whl` in the lock is never
fetched. The stand-in carries a marker the real wheel does not, which is what
proves the substitution rather than the wheel supplied the module.

That the lock still records the mismatched wheel is guarded once for every
scenario by //uv-dist-info-case-1394:lock_fixtures_test.
"""

import unittest
from pathlib import Path

import InquirerPy


class OverrideTargetTest(unittest.TestCase):
    def test_substitute_supplied_the_module(self) -> None:
        self.assertTrue(getattr(InquirerPy, "SUBSTITUTE", False))

    def test_wheel_was_never_installed(self) -> None:
        # The real wheel would have brought a `.dist-info` alongside it.
        site_packages = Path(InquirerPy.__file__).parent.parent
        self.assertEqual([], sorted(site_packages.glob("*nquirer*.dist-info")))


if __name__ == "__main__":
    unittest.main()
