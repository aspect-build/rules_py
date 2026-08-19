"""Exercise wheel projection and first-party namespace index records."""

from pathlib import Path
import tempfile
import unittest

from import_index import generate


class ImportIndexTest(unittest.TestCase):
    def _generate(self, records: list[str]) -> tuple[list[str], list[str]]:
        with tempfile.TemporaryDirectory(prefix="import-index-test-") as directory:
            path = Path(directory) / "records"
            path.write_text("\n".join(records) + "\n", encoding="utf-8")
            index, pth = generate(
                records_path=str(path),
                workspace="_main",
                escape="../../..",
                venv_escape="../..",
            )
        return index.splitlines(), pth.splitlines()

    def test_virtual_wheels_preserve_owner_and_metadata_order(self) -> None:
        index, _ = self._generate(
            [
                "R\t_main",
                "W\tnamespace/first\texternal/shared",
                "W\tfirst-1.dist-info\texternal/shared",
                "W\todd.name.py\texternal/shared",
                "W\tnamespace/second\texternal/shared-extra",
                "W\tother.name.pyc\texternal/shared-extra",
                "W\tnamespace/first_again\texternal/shared",
                "W\tnative.cpython-312-x86_64-linux-gnu.so\texternal/shared-extra",
                "W\tnamespace/nested.dist-info\texternal/shared-extra",
                "W\todd name\texternal/shared",
                "W\tsecond-1.egg-info\texternal/shared-extra",
            ]
        )

        self.assertEqual(
            [row for row in index if row.startswith(("I\t", "D\t"))],
            [
                "I\tnamespace\t../../../external/shared\t../../../external/shared-extra",
                "I\todd.name\t../../../external/shared",
                "I\tother.name\t../../../external/shared-extra",
                "I\tnative\t../../../external/shared-extra",
                "I\todd name\t../../../external/shared",
                "D\tfirst-1.dist-info\t../../../external/shared",
                "D\tsecond-1.egg-info\t../../../external/shared-extra",
            ],
        )

    def test_first_party_target_requires_no_wheel_records(self) -> None:
        index, pth = self._generate(
            [
                "R\t_main/project",
                "S\tproject/service.py",
            ]
        )

        self.assertIn("P\tservice\t1", index)
        self.assertFalse(any(row.startswith(("I\t", "D\t")) for row in index))
        self.assertTrue(any("_aspect_rules_py_import_index" in row for row in pth))

    def test_shared_first_party_namespaces_retain_each_owner(self) -> None:
        index, _ = self._generate(
            [
                "R\t_main/first",
                "R\t_main/second",
                "S\tfirst/shared/one.py",
                "S\tsecond/shared/two.py",
            ]
        )

        self.assertIn("P\tshared\t1\t2", index)
        self.assertIn("N\tshared.one\t1", index)
        self.assertIn("N\tshared.two\t2", index)


if __name__ == "__main__":
    unittest.main()
