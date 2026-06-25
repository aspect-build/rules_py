import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from site_merge import merge


def _write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(mode)


def _snapshot(path):
    if path.is_file():
        return (
            "file",
            path.read_bytes(),
            stat.S_IMODE(path.stat().st_mode) & 0o111,
        )
    return (
        "directory",
        tuple((child.name, _snapshot(child)) for child in sorted(path.iterdir())),
    )


class SiteMergeTest(unittest.TestCase):
    def test_unions_directories_independently_of_source_order(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            _write(first / "shared/identical.py", "same", 0o755)
            _write(first / "first.py", "first")
            _write(second / "shared/identical.py", "same", 0o755)
            _write(second / "shared/second.py", "second")
            (first / "link").symlink_to("shared/identical.py")
            (second / "link").symlink_to("shared/identical.py")

            forward = root / "forward"
            reverse = root / "reverse"
            merge(forward, [first, second])
            merge(reverse, [second, first])

            self.assertEqual(_snapshot(forward), _snapshot(reverse))
            self.assertEqual((forward / "first.py").read_text(), "first")
            self.assertEqual((forward / "shared/second.py").read_text(), "second")

    def test_conflicts_report_path_owners_and_reason(self):
        cases = {
            "content": ("regular file contents differ", "file", "file"),
            "executable": ("executable bits differ", "executable", "executable"),
            "file_directory": ("type differs", "file", "directory"),
        }
        for name, (reason, first_kind, second_kind) in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    first = root / "first"
                    second = root / "second"
                    self._make_conflict(first, first_kind, first=True)
                    self._make_conflict(second, second_kind, first=False)

                    result = subprocess.run(
                        [
                            sys.executable,
                            str(Path(__file__).with_name("site_merge.py")),
                            "--into",
                            str(root / "output"),
                            "--src",
                            str(second),
                            "--src",
                            str(first),
                        ],
                        capture_output=True,
                        text=True,
                    )

                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("entry", result.stderr)
                    self.assertIn(str(first), result.stderr)
                    self.assertIn(str(second), result.stderr)
                    self.assertIn(reason, result.stderr)
                    self.assertFalse((root / "output").exists())

    def test_rejects_non_directory_source(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.py"
            _write(source, "contents")

            with self.assertRaisesRegex(ValueError, "only directories can be merged"):
                merge(root / "output", [source])

    @staticmethod
    def _make_conflict(root, kind, first):
        path = root / "entry"
        if kind == "file":
            _write(path, "first" if first else "second")
        elif kind == "executable":
            _write(path, "same", 0o755 if first else 0o644)
        else:
            path.mkdir(parents=True)


if __name__ == "__main__":
    unittest.main()
