import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from site_merge import merge


class SiteMergeTest(unittest.TestCase):
    def test_cli_normalizes_directory_modes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source/child"
            source.mkdir(parents=True)
            (source / "module.py").write_text("")

            for inherited_umask in (0o077, 0o000):
                output = root / f"output-{inherited_umask:o}"
                wrapper = (
                    "import os, runpy, sys; "
                    f"os.umask({inherited_umask}); "
                    "script = sys.argv[1]; "
                    "sys.argv = sys.argv[1:]; "
                    "runpy.run_path(script, run_name='__main__')"
                )
                subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        wrapper,
                        str(Path(__file__).with_name("site_merge.py")),
                        "--into",
                        str(output),
                        "--src",
                        str(source.parent),
                    ],
                    check=True,
                )

                self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o755)
                self.assertEqual(
                    stat.S_IMODE((output / "child").stat().st_mode),
                    0o755,
                )

    def test_missing_source_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            first.mkdir()

            with self.assertRaisesRegex(
                FileNotFoundError,
                "Missing package merge sources: .*missing",
            ):
                merge(root / "output", [first, root / "missing"])

    def test_first_file_wins_over_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "output"
            first.mkdir()
            (first / "entry").write_text("first")
            (second / "entry").mkdir(parents=True)
            (second / "entry/child.py").write_text("second")

            conflicts = merge(output, [first, second])

            self.assertEqual((output / "entry").read_text(), "first")
            self.assertEqual([conflict[0] for conflict in conflicts], [Path("entry")])

    def test_first_directory_wins_over_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "output"
            (first / "entry").mkdir(parents=True)
            (first / "entry/child.py").write_text("first")
            second.mkdir()
            (second / "entry").write_text("second")

            conflicts = merge(output, [first, second])

            self.assertEqual((output / "entry/child.py").read_text(), "first")
            self.assertEqual([conflict[0] for conflict in conflicts], [Path("entry")])


if __name__ == "__main__":
    unittest.main()
