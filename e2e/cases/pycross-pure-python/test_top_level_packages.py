"""Verify that installed wheels have their top-level packages in site-packages.

This test works in two modes:
1. If PYCROSS_TEST_PACKAGES env var is set, it tests those packages (comma-separated).
2. Otherwise, it tests hardcoded packages (regex, IPython) for
   the requirements e2e workspace.

Packages are tested for importability and correct site-packages placement.
"""

import importlib
import importlib.util
import os
import sys
import unittest


class TopLevelPackagesTest(unittest.TestCase):
    """Check that top_level_paths from wheel inspection actually show up."""

    def _get_packages(self) -> list[str]:
        return [p.strip() for p in os.environ.get("PYCROSS_TEST_PACKAGES", "regex,IPython").split(",") if p.strip()]

    def test_packages_importable(self) -> None:
        """All expected packages should be importable."""
        for pkg in self._get_packages():
            with self.subTest(package=pkg):
                mod = importlib.import_module(pkg)
                self.assertIsNotNone(mod, f"{pkg} imported as None")

    def test_packages_resolve_to_site_packages(self) -> None:
        """All expected packages should resolve to files within site-packages."""
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
        """dist-info directories should not be added as sys.path entries."""
        for path in sys.path:
            basename = os.path.basename(path)
            self.assertFalse(
                basename.endswith(".dist-info"),
                f"dist-info directory should not be on sys.path: {path}",
            )


if __name__ == "__main__":
    unittest.main()
