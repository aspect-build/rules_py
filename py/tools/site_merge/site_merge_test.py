import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from site_merge import merge


class SiteMergeTest(unittest.TestCase):
    def run_strict_merge(self, root, first, second):
        return subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("site_merge.py")),
                "--into",
                str(root / "output"),
                "--collision-policy",
                "error",
                "--src",
                str(first),
                "--src",
                str(second),
            ],
            capture_output=True,
            text=True,
        )

    def test_last_file_wins_over_read_only_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "output"
            first.mkdir()
            second.mkdir()
            first_entry = first / "entry"
            first_entry.write_text("first")
            first_entry.chmod(0o444)
            (second / "entry").write_text("second")

            conflicts = merge(output, [first, second])

            self.assertEqual((output / "entry").read_text(), "second")
            self.assertEqual([conflict[0] for conflict in conflicts], [Path("entry")])

    def test_last_directory_wins_over_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "output"
            first.mkdir()
            first_entry = first / "entry"
            first_entry.write_text("first")
            first_entry.chmod(0o444)
            (second / "entry").mkdir(parents=True)
            (second / "entry/child.py").write_text("second")

            conflicts = merge(output, [first, second])

            self.assertEqual((output / "entry/child.py").read_text(), "second")
            self.assertEqual([conflict[0] for conflict in conflicts], [Path("entry")])

    def test_last_file_wins_over_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "output"
            (first / "entry").mkdir(parents=True)
            first_child = first / "entry/child.py"
            first_child.write_text("first")
            first_child.chmod(0o444)
            second.mkdir()
            (second / "entry").write_text("second")

            conflicts = merge(output, [first, second])

            self.assertEqual((output / "entry").read_text(), "second")
            self.assertEqual([conflict[0] for conflict in conflicts], [Path("entry")])

    def test_identical_later_file_mode_wins_without_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "output"
            first.mkdir()
            second.mkdir()
            first_entry = first / "entry"
            second_entry = second / "entry"
            first_entry.write_text("identical")
            second_entry.write_text("identical")
            first_entry.chmod(0o444)
            second_entry.chmod(0o755)

            conflicts = merge(output, [first, second])

            self.assertEqual(conflicts, [])
            self.assertEqual(
                stat.S_IMODE((output / "entry").stat().st_mode),
                stat.S_IMODE(second_entry.stat().st_mode),
            )

    def test_error_policy_rejects_a_collision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            (first / "entry").write_text("first")
            (second / "entry").write_text("second")

            result = self.run_strict_merge(root, first, second)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Package collision", result.stdout)

    def test_error_policy_accepts_identical_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            (first / "entry").write_text("identical")
            (second / "entry").write_text("identical")

            result = self.run_strict_merge(root, first, second)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_error_policy_unions_disjoint_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            (first / "one").mkdir(parents=True)
            (second / "two").mkdir(parents=True)
            (first / "one/module.py").write_text("one")
            (second / "two/module.py").write_text("two")

            result = self.run_strict_merge(root, first, second)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "output/one/module.py").read_text(), "one")
            self.assertEqual((root / "output/two/module.py").read_text(), "two")

    def test_error_policy_rejects_file_directory_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            (second / "entry").mkdir(parents=True)
            (first / "entry").write_text("file")

            result = self.run_strict_merge(root, first, second)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Package collision", result.stdout)

    def test_missing_source_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)

            with self.assertRaisesRegex(
                FileNotFoundError,
                "declared merge source is not a directory",
            ):
                merge(root / "output", [root / "missing"])


if __name__ == "__main__":
    unittest.main()
