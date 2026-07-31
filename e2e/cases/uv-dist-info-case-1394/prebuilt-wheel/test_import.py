"""#1394 via the wheel itself: the archive names its own metadata directory.

This is the only scenario that actually fetches the mismatched wheel and reads
its `.dist-info`. None of the three filenames are PEP 625-normalized, so all
three take the discovery path rather than stripping the implied prefix:

  * `InquirerPy-0.3.4-py3-none-any.whl` ships `inquirerpy-0.3.4.dist-info` —
    the case really does differ, which is what #1394 reported.
  * `XlsxWriter-3.1.9-py3-none-any.whl` ships a `.data/scripts/` member, so the
    discovered stem has to name the `.data` sibling too.
  * `jaraco.classes-3.4.0-py3-none-any.whl` is spelled with a dot.

That the lock still pins those filenames is guarded by
//uv-dist-info-case-1394:lock_fixtures_test.
"""

import unittest
from pathlib import Path

import InquirerPy
import xlsxwriter
from InquirerPy import inquirer
from jaraco.classes import properties


class DistInfoCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.site_packages = Path(InquirerPy.__file__).parent.parent

    def test_metadata_directory_came_from_the_archive(self) -> None:
        # `InquirerPy-0.3.4-py3-none-any.whl` implies `InquirerPy-0.3.4.dist-info`;
        # the archive ships the lowercase spelling, and that is what installs.
        found = [
            path.name
            for path in self.site_packages.glob("*.dist-info")
            if path.name.lower().startswith("inquirerpy-")
        ]
        self.assertEqual(["inquirerpy-0.3.4.dist-info"], found)

    def test_package_installed(self) -> None:
        self.assertIsNotNone(inquirer.text)
        self.assertTrue((self.site_packages / "InquirerPy").is_dir())
        self.assertIsNotNone(xlsxwriter.Workbook)
        self.assertIsNotNone(properties.NonDataProperty)

    def test_data_members_routed(self) -> None:
        # XlsxWriter ships `XlsxWriter-3.1.9.data/scripts/vba_extract.py`, which
        # PEP 427 routes out of site-packages. A `.data` stem that doesn't match
        # the archive's matches no member, leaving the directory to install as a
        # literal top-level here.
        self.assertEqual([], sorted(self.site_packages.glob("*.data")))


if __name__ == "__main__":
    unittest.main()
