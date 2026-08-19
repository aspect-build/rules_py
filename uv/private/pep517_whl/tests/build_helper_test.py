"""Unit tests for build_helper's pure helpers.

These exist because build_helper.py is import-safe: the CLI body lives
under main(), so the module's functions can be exercised directly. The
import at the top of this file is itself the regression test for that
guard — before it, importing the module ran the build.
"""

import os
import tempfile
import unittest
from os import path

from uv.private.pep517_whl.tools import build_helper


def _make_executable(directory: str, name: str) -> str:
    exe = path.join(directory, name)
    with open(exe, "w") as f:
        f.write("#!/bin/sh\n")
    os.chmod(exe, 0o755)
    return exe


class ImportSafetyTest(unittest.TestCase):
    def test_main_is_exposed_not_executed(self) -> None:
        self.assertTrue(callable(build_helper.main))


class AbsolutizePathTest(unittest.TestCase):
    def test_empty_stays_empty(self) -> None:
        self.assertEqual(build_helper._absolutize_path(""), "")

    def test_absolute_untouched(self) -> None:
        self.assertEqual(build_helper._absolutize_path("/usr/bin/cc"), "/usr/bin/cc")

    def test_relative_resolves_against_cwd(self) -> None:
        self.assertEqual(
            build_helper._absolutize_path("bin/cc"),
            path.join(os.getcwd(), "bin/cc"),
        )


class ResolveCompilerPathTest(unittest.TestCase):
    def test_missing_key_returns_default(self) -> None:
        self.assertEqual(build_helper._resolve_compiler_path({}, "CC", "cc"), "cc")

    def test_empty_value_returns_default(self) -> None:
        self.assertEqual(build_helper._resolve_compiler_path({"CC": ""}, "CC", "cc"), "cc")

    def test_pathful_value_is_absolutized(self) -> None:
        env = {"CC": "external/toolchain/bin/gcc"}
        self.assertEqual(
            build_helper._resolve_compiler_path(env, "CC", "cc"),
            path.join(os.getcwd(), "external/toolchain/bin/gcc"),
        )

    def test_flags_after_the_driver_are_ignored(self) -> None:
        env = {"CC": "/opt/bin/gcc -pthread"}
        self.assertEqual(build_helper._resolve_compiler_path(env, "CC", "cc"), "/opt/bin/gcc")

    def test_bare_name_resolves_on_env_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            exe = _make_executable(tmp, "mycc")
            env = {"CC": "mycc", "PATH": tmp}
            self.assertEqual(build_helper._resolve_compiler_path(env, "CC", "cc"), exe)

    def test_bare_name_not_on_path_passes_through(self) -> None:
        env = {"CC": "no-such-compiler", "PATH": "/nonexistent"}
        self.assertEqual(
            build_helper._resolve_compiler_path(env, "CC", "cc"),
            "no-such-compiler",
        )


class LocalCxxCompanionTest(unittest.TestCase):
    def test_no_current_returns_compiler(self) -> None:
        self.assertEqual(build_helper._local_cxx_companion(None, "/opt/gcc"), "/opt/gcc")

    def test_relative_current_returns_compiler(self) -> None:
        self.assertEqual(build_helper._local_cxx_companion("gcc", "/opt/gcc"), "/opt/gcc")

    def test_gcc_finds_sibling_gxx(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            gcc = _make_executable(tmp, "gcc")
            gxx = _make_executable(tmp, "g++")
            self.assertEqual(build_helper._local_cxx_companion(gcc, gcc), gxx)

    def test_versioned_clang_finds_versioned_companion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            clang = _make_executable(tmp, "clang-15")
            clangxx = _make_executable(tmp, "clang++-15")
            self.assertEqual(build_helper._local_cxx_companion(clang, clang), clangxx)

    def test_prefixed_cc_finds_prefixed_cxx(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cc = _make_executable(tmp, "aarch64-linux-gnu-gcc")
            cxx = _make_executable(tmp, "aarch64-linux-gnu-g++")
            self.assertEqual(build_helper._local_cxx_companion(cc, cc), cxx)

    def test_missing_companion_returns_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            gcc = _make_executable(tmp, "gcc")
            self.assertEqual(build_helper._local_cxx_companion(gcc, gcc), gcc)

    def test_non_compiler_stem_returns_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tool = _make_executable(tmp, "rustc")
            _make_executable(tmp, "rustc++")
            self.assertEqual(build_helper._local_cxx_companion(tool, tool), tool)


class OverrideToolTest(unittest.TestCase):
    def test_absent_key_is_untouched(self) -> None:
        env = {}
        build_helper._override_tool(env, "CC", "/wrap/cc")
        self.assertNotIn("CC", env)

    def test_driver_swapped_flags_preserved(self) -> None:
        env = {"LDSHARED": "gcc -shared -pthread"}
        build_helper._override_tool(env, "LDSHARED", "/wrap/cc")
        self.assertEqual(env["LDSHARED"], "/wrap/cc -shared -pthread")


class MakeCompilerWrapperTest(unittest.TestCase):
    def test_wrapper_is_executable_and_bakes_the_driver(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = build_helper._make_compiler_wrapper(tmp, "cc", "/opt/real-cc")
            self.assertTrue(os.access(wrapper, os.X_OK))
            with open(wrapper) as f:
                content = f.read()
            self.assertIn("/opt/real-cc", content)
            self.assertIn(build_helper._DEBUG_FLAG, content)


class LegacyMetadataConflictTest(unittest.TestCase):
    def _worktree(
        self,
        tmp: str,
        pyproject: str | None = None,
        setup_py: str | None = None,
        setup_cfg: str | None = None,
    ) -> str:
        if pyproject is not None:
            with open(path.join(tmp, "pyproject.toml"), "w") as f:
                f.write(pyproject)
        if setup_py is not None:
            with open(path.join(tmp, "setup.py"), "w") as f:
                f.write(setup_py)
        if setup_cfg is not None:
            with open(path.join(tmp, "setup.cfg"), "w") as f:
                f.write(setup_cfg)
        return tmp

    _SETUPTOOLS_PYPROJECT = (
        '[build-system]\nbuild-backend = "setuptools.build_meta"\n'
        '[project]\nname = "pkg"\nversion = "1.0"\n'
    )

    def test_no_pyproject_is_no_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(tmp, setup_py="install_requires=['x']")
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_setup_py_install_requires_undeclared_in_pyproject_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT,
                setup_py="setup(install_requires=['x'])",
            )
            self.assertTrue(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_static_dependencies_win_over_setup_py(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT + 'dependencies = ["y"]\n',
                setup_py="setup(install_requires=['x'])",
            )
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_dynamic_dependencies_declaration_is_no_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT + 'dynamic = ["dependencies"]\n',
                setup_py="setup(install_requires=['x'])",
            )
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_non_setuptools_backend_is_no_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=(
                    '[build-system]\nbuild-backend = "mesonpy"\n'
                    '[project]\nname = "pkg"\nversion = "1.0"\n'
                ),
                setup_py="setup(install_requires=['x'])",
            )
            self.assertFalse(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))

    def test_extras_require_in_setup_cfg_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self._worktree(
                tmp,
                pyproject=self._SETUPTOOLS_PYPROJECT + 'dependencies = ["y"]\n',
                setup_py="setup()",
                setup_cfg="[options.extras_require]\ndev = pytest",
            )
            self.assertTrue(build_helper._legacy_metadata_conflicts_with_pyproject(tmp))


if __name__ == "__main__":
    unittest.main()
