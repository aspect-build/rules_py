import runpy
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import site_merge
from site_merge import merge


def _write(path: Path, content: str, mode: int | None = None) -> None:
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

    def test_cache_source_path_matches_the_shared_vectors(self) -> None:
        vectors = runpy.run_path(
            str(Path(site_merge.__file__).parents[1] / "unpack" / "exclude_glob_test_vectors.bzl")
        )
        for path, expected in vectors["CACHE_SOURCE_VECTORS"]:
            source = site_merge.cache_source_path(Path(path))
            self.assertEqual(source, expected and Path(expected), path)

    def test_bytecode_orphaned_by_an_overlay_is_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            _write(first / "pkg/overlaid.py", "first")
            _write(first / "pkg/__pycache__/overlaid.cpython-311.pyc", "first bytecode")
            _write(first / "pkg/kept.py", "first")
            _write(first / "pkg/__pycache__/kept.cpython-311.pyc", "kept bytecode")
            _write(first / "pkg/__pycache__/sourceless.cpython-311.pyc", "no source")
            _write(first / "pkg/dotted.v1.py", "first")
            _write(
                first / "pkg/__pycache__/dotted.v1.cpython-311.pyc", "dotted bytecode"
            )
            _write(first / "pkg/optimized.py", "first")
            _write(
                first / "pkg/__pycache__/optimized.cpython-311.opt-2.pyc",
                "optimized bytecode",
            )

            _write(second / "pkg/overlaid.py", "second")
            _write(second / "pkg/dotted.v1.py", "second")
            _write(second / "pkg/optimized.py", "second")
            _write(second / "pkg/recompiled.py", "second")
            _write(
                second / "pkg/__pycache__/recompiled.cpython-311.pyc",
                "second bytecode",
            )

            merge(output, [first, second])

            self.assertFalse(
                (output / "pkg/__pycache__/overlaid.cpython-311.pyc").exists()
            )
            self.assertFalse(
                (output / "pkg/__pycache__/dotted.v1.cpython-311.pyc").exists()
            )
            self.assertFalse(
                (output / "pkg/__pycache__/optimized.cpython-311.opt-2.pyc").exists()
            )
            self.assertEqual(
                (output / "pkg/__pycache__/kept.cpython-311.pyc").read_text(),
                "kept bytecode",
            )
            self.assertEqual(
                (output / "pkg/__pycache__/sourceless.cpython-311.pyc").read_text(),
                "no source",
            )
            self.assertEqual(
                (output / "pkg/__pycache__/recompiled.cpython-311.pyc").read_text(),
                "second bytecode",
            )

    def test_bytecode_survives_an_identical_source_from_another_wheel(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            _write(first / "pkg/shared.py", "same")
            _write(first / "pkg/__pycache__/shared.cpython-311.pyc", "first bytecode")
            _write(second / "pkg/shared.py", "same")

            merge(output, [first, second])

            self.assertEqual(
                (output / "pkg/__pycache__/shared.cpython-311.pyc").read_text(),
                "first bytecode",
            )

    def test_bytecode_from_a_later_wheel_survives_an_earlier_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            _write(first / "pkg/source_only.py", "first")
            _write(first / "pkg/replaced.py", "first")
            _write(first / "pkg/__pycache__/replaced.cpython-311.pyc", "first bytecode")

            _write(
                second / "pkg/__pycache__/source_only.cpython-311.pyc",
                "second bytecode",
            )
            _write(
                second / "pkg/__pycache__/replaced.cpython-311.pyc", "second bytecode"
            )

            merge(output, [first, second])

            self.assertEqual(
                (output / "pkg/__pycache__/source_only.cpython-311.pyc").read_text(),
                "second bytecode",
            )
            self.assertEqual(
                (output / "pkg/__pycache__/replaced.cpython-311.pyc").read_text(),
                "second bytecode",
            )

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
