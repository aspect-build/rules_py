"""#1394 where the filename gives no warning that it disagrees with the archive.

The sibling scenarios all pin an unescaped filename, which is itself the signal
that the implied `.dist-info` is only a guess. `actioneer-0.0.1-py3-none-any.whl`
carries no such signal: project and version are both already normalized, so the
implied `actioneer-0.0.1.dist-info` looks authoritative and is stripped as an
archive path prefix. The archive ships `Actioneer-0.0.1.dist-info`, so nothing
in it carries that prefix.

The wheel installs no importable top-level -- its RECORD lists the `.dist-info`
and nothing else -- so the metadata directory is the whole installed tree, and
the assertions read it rather than an imported module.

That the lock still pins the normalized filename is guarded by
//uv-dist-info-case-1394:lock_fixtures_test.
"""

import unittest
from importlib.metadata import distribution
from pathlib import Path


class ArchivePrefixTest(unittest.TestCase):
    def setUp(self) -> None:
        self.distribution = distribution("actioneer")
        self.site_packages = Path(self.distribution.locate_file(""))

    def test_metadata_directory_came_from_the_archive(self) -> None:
        # The filename implies `actioneer-0.0.1.dist-info`; the archive ships
        # the capitalized spelling, and that is what installs.
        found = [
            path.name
            for path in self.site_packages.glob("*.dist-info")
            if path.name.lower().startswith("actioneer-")
        ]
        self.assertEqual(["Actioneer-0.0.1.dist-info"], found)

    def test_metadata_is_readable(self) -> None:
        self.assertEqual("0.0.1", self.distribution.version)


if __name__ == "__main__":
    unittest.main()
