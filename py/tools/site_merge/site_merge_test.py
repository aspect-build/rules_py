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

    def test_namespace_stub_forms(self) -> None:
        stubs = {
            "guide pkgutil": "__path__ = __import__('pkgutil').extend_path(__path__, __name__)\n",
            "guide pkgutil crlf, no newline": "__path__ = __import__(\"pkgutil\").extend_path(__path__, __name__)",
            "setuptools pkg_resources": "__import__('pkg_resources').declare_namespace(__name__)\n",
            "from import": "from pkgutil import extend_path\n__path__ = extend_path(__path__, __name__)\n",
            "plain import": "import pkgutil\n__path__ = pkgutil.extend_path(__path__, __name__)\n",
            "plain pkg_resources import": "import pkg_resources\npkg_resources.declare_namespace(__name__)\n",
            "from pkg_resources import": "from pkg_resources import declare_namespace\ndeclare_namespace(__name__)\n",
            "aliased import": "from pkgutil import extend_path as ep\n__path__ = ep(__path__, __name__)\n",
            "aliased module": "import pkgutil as pk\n__path__ = pk.extend_path(__path__, __name__)\n",
            "try except ImportError": (
                "try:\n"
                "    __import__('pkg_resources').declare_namespace(__name__)\n"
                "except ImportError:\n"
                "    __path__ = __import__('pkgutil').extend_path(__path__, __name__)\n"
            ),
            "try with imports in both branches": (
                "try:\n"
                "    import pkg_resources\n"
                "    pkg_resources.declare_namespace(__name__)\n"
                "except ImportError:\n"
                "    from pkgutil import extend_path\n"
                "    __path__ = extend_path(__path__, __name__)\n"
            ),
            "docstring and comments": (
                '"""Namespace package."""\n'
                "# See https://pypi.python.org/pypi/backports\n\n"
                "from pkgutil import extend_path\n"
                "__path__ = extend_path(__path__, __name__)  # noqa\n"
            ),
            "future import": "from __future__ import annotations\n__path__ = __import__('pkgutil').extend_path(__path__, __name__)\n",
            "empty": "",
            "comment only": "# nothing here\n",
            "docstring only": '"""Only a docstring."""\n',
            "latin-1 cookie": "# -*- coding: latin-1 -*-\n# caf\xe9\n__path__ = __import__('pkgutil').extend_path(__path__, __name__)\n",
        }
        for name, source in stubs.items():
            with self.subTest(name):
                self.assertTrue(site_merge.is_namespace_stub(source.encode("latin-1")))

        code = {
            "extra assignment": "from pkgutil import extend_path\n__path__ = extend_path(__path__, __name__)\nX = 1\n",
            "other import": "import os\n__path__ = __import__('pkgutil').extend_path(__path__, __name__)\n",
            "try except pass": "try:\n    import simplejson\nexcept:\n    pass\n",
            "wrong arguments": "__path__ = __import__('pkgutil').extend_path(__path__)\n",
            "wrong target": "path = __import__('pkgutil').extend_path(__path__, __name__)\n",
            "keyword arguments": "__import__('pkg_resources').declare_namespace(name=__name__)\n",
            "wrong function": "import pkgutil\n__path__ = pkgutil.walk_packages(__path__, __name__)\n",
            "unbound name": "__path__ = extend_path(__path__, __name__)\n",
            "try with else": (
                "try:\n"
                "    import pkg_resources\n"
                "except ImportError:\n"
                "    pass\n"
                "else:\n"
                "    pkg_resources.declare_namespace(__name__)\n"
            ),
            "syntax error": "__path__ = (\n",
            "undecodable": "\xff\xfe__path__ = 1\n",
        }
        for name, source in code.items():
            with self.subTest(name):
                self.assertFalse(site_merge.is_namespace_stub(source.encode("latin-1")))

    def test_namespace_init_stubs_treated_as_equivalent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            _write(
                first / "backports/__init__.py",
                "from pkgutil import extend_path\n__path__ = extend_path(__path__, __name__)\n",
            )
            _write(first / "backports/weakref.py", "VALUE = 'first'\n")
            _write(
                second / "backports/__init__.py",
                "# See https://pypi.python.org/pypi/backports\n\n"
                "from pkgutil import extend_path\n"
                "__path__ = extend_path(__path__, __name__)\n",
            )
            _write(second / "backports/shutil_get_terminal_size.py", "VALUE = 'second'\n")

            conflicts = merge(output, [first, second])

            self.assertEqual(conflicts, [])
            self.assertEqual((output / "backports/weakref.py").read_text(), "VALUE = 'first'\n")
            self.assertEqual(
                (output / "backports/shutil_get_terminal_size.py").read_text(),
                "VALUE = 'second'\n",
            )

    def test_namespace_init_stub_with_extra_code_is_collision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            _write(
                first / "backports/__init__.py",
                "from pkgutil import extend_path\n__path__ = extend_path(__path__, __name__)\n",
            )
            _write(
                second / "backports/__init__.py",
                "from pkgutil import extend_path\n__path__ = extend_path(__path__, __name__)\nX = 1\n",
            )

            conflicts = merge(output, [first, second])

            self.assertEqual(
                {path.name for path, _previous, _current in conflicts},
                {"__init__.py"},
            )

    def test_undecodable_init_files_conflict_instead_of_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "first"
            second = root / "second"
            output = root / "output"

            (first / "pkg").mkdir(parents=True)
            (first / "pkg/__init__.py").write_bytes(b"# caf\xe9\nX = 1\n")
            (second / "pkg").mkdir(parents=True)
            (second / "pkg/__init__.py").write_bytes(b"# caf\xe9\nX = 2\n")

            conflicts = merge(output, [first, second])

            self.assertEqual(
                {path.name for path, _previous, _current in conflicts},
                {"__init__.py"},
            )
            self.assertEqual((output / "pkg/__init__.py").read_bytes(), b"# caf\xe9\nX = 2\n")


if __name__ == "__main__":
    unittest.main()
