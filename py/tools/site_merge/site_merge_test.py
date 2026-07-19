import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional

from site_merge import merge


def _write(path: Path, content: str, mode: Optional[int] = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if mode is not None:
        path.chmod(mode)


class SiteMergeTest(unittest.TestCase):
    def test_later_source_overlays_earlier_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            _write(first / "distinct", "first", 0o444)
            _write(first / "identical", "same", 0o644)
            _write(first / "identical_executable", "same", 0o700)
            _write(first / "executable_changed", "same", 0o644)
            _write(first / "file_to_directory", "first", 0o444)
            _write(first / "directory_to_file/child.py", "first", 0o444)
            _write(first / "union/first.py", "first")

            _write(second / "distinct", "second")
            _write(second / "identical", "same", 0o600)
            _write(second / "identical_executable", "same", 0o711)
            _write(second / "executable_changed", "same", 0o755)
            _write(second / "file_to_directory/child.py", "second")
            _write(second / "directory_to_file", "second")
            _write(second / "union/second.py", "second")

            conflicts = merge(output, [first, second])

            self.assertEqual(
                {
                    (path, previous.name, current.name)
                    for path, previous, current in conflicts
                },
                {
                    (Path("distinct"), "first", "second"),
                    (Path("file_to_directory"), "first", "second"),
                    (Path("directory_to_file"), "first", "second"),
                    (Path("executable_changed"), "first", "second"),
                },
            )
            self.assertEqual((output / "distinct").read_text(), "second")
            self.assertEqual(
                (output / "file_to_directory/child.py").read_text(), "second"
            )
            self.assertEqual((output / "directory_to_file").read_text(), "second")
            self.assertEqual((output / "union/first.py").read_text(), "first")
            self.assertEqual((output / "union/second.py").read_text(), "second")
            self.assertEqual(
                stat.S_IMODE((output / "identical").stat().st_mode),
                0o600,
            )
            self.assertEqual(
                stat.S_IMODE((output / "identical_executable").stat().st_mode),
                0o711,
            )
            self.assertEqual(
                stat.S_IMODE((output / "executable_changed").stat().st_mode),
                0o755,
            )

            self.assertEqual((first / "distinct").read_text(), "first")
            self.assertEqual(
                (first / "directory_to_file/child.py").read_text(), "first"
            )
            self.assertEqual(stat.S_IMODE((first / "distinct").stat().st_mode), 0o444)

    def test_collision_policy_controls_reporting_and_status(self) -> None:
        for policy in ("warning", "ignore", "error"):
            with (
                self.subTest(policy=policy),
                tempfile.TemporaryDirectory() as temporary_directory,
            ):
                root = Path(temporary_directory)
                first = root / "first"
                second = root / "second"
                output = root / "output"
                _write(first / "entry", "first")
                _write(second / "entry/child.py", "second")

                result = subprocess.run(
                    [
                        sys.executable,
                        str(Path(__file__).with_name("site_merge.py")),
                        "--into",
                        str(output),
                        "--collision-policy",
                        policy,
                        "--src",
                        str(first),
                        "--src",
                        str(second),
                    ],
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(result.stdout, "")
                if policy == "ignore":
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stderr, "")
                else:
                    self.assertIn("Package collision", result.stderr)
                    self.assertIn(str(first), result.stderr)
                    self.assertIn(str(second), result.stderr)
                    if policy == "warning":
                        self.assertEqual(result.returncode, 0)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                if policy != "error":
                    self.assertEqual((output / "entry/child.py").read_text(), "second")


if __name__ == "__main__":
    unittest.main()
