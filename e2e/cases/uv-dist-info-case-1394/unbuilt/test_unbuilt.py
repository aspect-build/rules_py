"""#1394 via demand: a locked wheel nothing depends on is never installed.

Repos are declared for every wheel in the lock, but Bazel only runs a repo rule
when a label inside it is demanded. This target depends on cowsay alone, so the
mismatched `InquirerPy-0.3.4-py3-none-any.whl` stays in the lock and no
`whl_install__..._unbuilt__inquirerpy__0_3_4` repo is ever created.

The `whl_dist` download repo is keyed by wheel URL rather than by hub, so the
sibling case that does depend on the package shares it. That makes the skipped
*download* unobservable from here; what this asserts is the skipped install.

That the lock still records the mismatched wheel is guarded once for every
scenario by //uv-dist-info-case-1394:lock_fixtures_test.
"""

import unittest
from pathlib import Path

import cowsay


class UnbuiltTest(unittest.TestCase):
    def test_only_the_depended_on_package_installed(self) -> None:
        site_packages = Path(cowsay.__file__).parent.parent
        self.assertIsNotNone(cowsay.cow)
        self.assertEqual([], sorted(site_packages.glob("*nquirer*")))


if __name__ == "__main__":
    unittest.main()
