"""Assert that source-built wheels land their top-level packages in site-packages.

Ported from rules_pycross's shared top-level-packages check. The packages to
verify come from the comma-separated `PYCROSS_TEST_PACKAGES` env var, set by
the consuming py_test. Three invariants per package: it imports, its module
spec resolves inside site-packages rather than a leaked source tree or
`PYTHONPATH` entry, and no dist-info directory ends up on `sys.path`.
"""

import importlib
import importlib.util
import os
import sys
import unittest


class TopLevelPackagesTest(unittest.TestCase):
    def _get_packages(self) -> list[str]:
        return [p.strip() for p in os.environ["PYCROSS_TEST_PACKAGES"].split(",") if p.strip()]

    def test_packages_importable(self) -> None:
        for pkg in self._get_packages():
            with self.subTest(package=pkg):
                mod = importlib.import_module(pkg)
                self.assertIsNotNone(mod, f"{pkg} imported as None")

    def test_packages_resolve_to_site_packages(self) -> None:
        for pkg in self._get_packages():
            with self.subTest(package=pkg):
                spec = importlib.util.find_spec(pkg)
                self.assertIsNotNone(spec, f"{pkg} module spec not found")
                self.assertIsNotNone(spec.origin, f"{pkg} has no origin (namespace package?)")
                self.assertIn(
                    "site-packages",
                    spec.origin,
                    f"{pkg} origin not in site-packages: {spec.origin}",
                )

    def test_no_dist_info_on_sys_path(self) -> None:
        for path in sys.path:
            basename = os.path.basename(path)
            self.assertFalse(
                basename.endswith(".dist-info"),
                f"dist-info directory should not be on sys.path: {path}",
            )


if __name__ == "__main__":
    unittest.main()
