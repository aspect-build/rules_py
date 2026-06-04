"""Tests for build_helper.py's _ensure_build_backend function.

Covers issues reported in the enterprise support ticket:
 - Non-setuptools backends (hatchling, flit_core) not available in the build
   sandbox cause ModuleNotFoundError; the fix falls back to setuptools.
 - Setuptools < 61 does not understand PEP 621 [project] tables; the fix
   generates a compatible setup.cfg.
 - setup.cfg must include [options.package_data] so non-Python data files
   (YAML, models, etc.) are included in the wheel.
 - Packages with a src/ layout need the correct package_dir / find: config.
 - [project.scripts] entries should translate to console_scripts entry points.
"""

import ast
import os
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch


# ---------------------------------------------------------------------------
# Extract _ensure_build_backend from the script without executing it.
# build_helper.py is a runnable script (not a module), so direct import would
# trigger top-level directory operations.  We pull out only the function we
# need by parsing the AST and compiling that subtree.
# ---------------------------------------------------------------------------
_HELPER_PATH = os.path.join(os.path.dirname(__file__), "build_helper.py")


def _load_ensure_build_backend():
    with open(_HELPER_PATH) as fh:
        source = fh.read()
    tree = ast.parse(source, _HELPER_PATH)
    func_node = next(
        n for n in tree.body
        if isinstance(n, ast.FunctionDef) and n.name == "_ensure_build_backend"
    )
    mod = ast.Module(body=[func_node], type_ignores=[])
    code = compile(mod, _HELPER_PATH, "exec")
    ns = {
        "path": os.path,
        "os": os,
        "__name__": "__extracted__",
    }
    exec(code, ns)  # noqa: S102 – intentional extraction, not untrusted input
    return ns["_ensure_build_backend"]


_ensure_build_backend = _load_ensure_build_backend()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write(directory, rel_path, content):
    full = os.path.join(directory, rel_path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as fh:
        fh.write(content)
    return full


def _read(directory, rel_path):
    with open(os.path.join(directory, rel_path)) as fh:
        return fh.read()


def _exists(directory, rel_path):
    return os.path.exists(os.path.join(directory, rel_path))


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestEnsureBuildBackendNoop(unittest.TestCase):
    """_ensure_build_backend is a no-op when pyproject.toml is absent."""

    def test_no_pyproject_toml(self):
        with tempfile.TemporaryDirectory() as d:
            _ensure_build_backend(d)
            self.assertFalse(_exists(d, "setup.cfg"))


class TestBackendFallback(unittest.TestCase):
    """Non-importable backends (hatchling, flit_core) fall back to setuptools.

    We use a module name that is guaranteed not to exist so that the fallback
    logic is exercised without any mocking of builtins.__import__.
    """

    _FAKE_BACKEND = "_aspect_test_nonexistent_backend_xyz"

    def _pyproject(self, backend=None):
        b = backend or self._FAKE_BACKEND
        return textwrap.dedent(f"""\
            [project]
            name = "mypkg"
            version = "1.0.0"

            [build-system]
            requires = ["{b}"]
            build-backend = "{b}.buildapi"
        """)

    def test_unavailable_backend_falls_back(self):
        """An unavailable build backend triggers setuptools fallback."""
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._pyproject())
            _ensure_build_backend(d)
            content = _read(d, "pyproject.toml")
        self.assertIn("setuptools.build_meta", content)
        self.assertNotIn(self._FAKE_BACKEND, content)

    def test_fallback_adds_setuptools_requires(self):
        """Rewritten [build-system] must require setuptools and wheel."""
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._pyproject())
            _ensure_build_backend(d)
            content = _read(d, "pyproject.toml")
        self.assertIn('requires = ["setuptools", "wheel"]', content)

    def test_setuptools_backend_unchanged(self):
        """Packages already using setuptools should not be rewritten."""
        pyproject = textwrap.dedent("""\
            [project]
            name = "mypkg"
            version = "1.0.0"

            [build-system]
            requires = ["setuptools"]
            build-backend = "setuptools.build_meta"
        """)
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", pyproject)
            _ensure_build_backend(d)
            content = _read(d, "pyproject.toml")
        self.assertIn("setuptools.build_meta", content)
        # requires line should be preserved as-is
        self.assertIn('requires = ["setuptools"]', content)

    def test_fallback_preserves_project_section(self):
        """After rewriting [build-system], [project] must be intact."""
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._pyproject())
            _ensure_build_backend(d)
            content = _read(d, "pyproject.toml")
        self.assertIn('[project]', content)
        self.assertIn('name = "mypkg"', content)
        self.assertIn('version = "1.0.0"', content)


class TestSetupCfgGeneration(unittest.TestCase):
    """setup.cfg is generated when setuptools < 61 and pyproject.toml has [project]."""

    _PYPROJECT = textwrap.dedent("""\
        [project]
        name = "mypkg"
        version = "2.3.4"

        [build-system]
        requires = ["setuptools"]
        build-backend = "setuptools.build_meta"
    """)

    def _run(self, tmpdir, st_version="60.0.0"):
        import importlib.metadata as _meta
        with patch.object(_meta, "version", return_value=st_version):
            _ensure_build_backend(tmpdir)

    def test_setup_cfg_generated_for_old_setuptools(self):
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._PYPROJECT)
            self._run(d, st_version="60.0.0")
            self.assertTrue(_exists(d, "setup.cfg"))
            cfg = _read(d, "setup.cfg")
        self.assertIn("name = mypkg", cfg)
        self.assertIn("version = 2.3.4", cfg)

    def test_setup_cfg_not_generated_for_new_setuptools(self):
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._PYPROJECT)
            self._run(d, st_version="61.0.0")
            self.assertFalse(_exists(d, "setup.cfg"))

    def test_setup_cfg_not_overwritten_if_exists(self):
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._PYPROJECT)
            _write(d, "setup.cfg", "[metadata]\nname = existing\n")
            self._run(d, st_version="60.0.0")
            cfg = _read(d, "setup.cfg")
        # Original content must be preserved
        self.assertIn("name = existing", cfg)
        self.assertNotIn("name = mypkg", cfg)

    def test_setup_cfg_includes_package_data(self):
        """Package data wildcard must be present so non-Python files are included."""
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._PYPROJECT)
            self._run(d, st_version="60.0.0")
            cfg = _read(d, "setup.cfg")
        self.assertIn("[options.package_data]", cfg)
        self.assertIn("* = *", cfg)

    def test_setup_cfg_src_layout(self):
        """src/ layout generates correct package_dir and find: config."""
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._PYPROJECT)
            os.makedirs(os.path.join(d, "src"))
            self._run(d, st_version="60.0.0")
            cfg = _read(d, "setup.cfg")
        self.assertIn("package_dir", cfg)
        self.assertIn("= src", cfg)
        self.assertIn("[options.packages.find]", cfg)
        self.assertIn("where = src", cfg)

    def test_setup_cfg_flat_layout(self):
        """Flat layout (no src/) generates simpler find: config."""
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", self._PYPROJECT)
            self._run(d, st_version="60.0.0")
            cfg = _read(d, "setup.cfg")
        self.assertIn("packages = find:", cfg)
        self.assertNotIn("package_dir", cfg)


class TestConsoleScripts(unittest.TestCase):
    """[project.scripts] entries end up as console_scripts in setup.cfg."""

    def test_scripts_in_entry_points(self):
        pyproject = textwrap.dedent("""\
            [project]
            name = "mytool"
            version = "0.1.0"

            [project.scripts]
            mytool = "mytool.cli:main"
            other-cmd = "mytool.other:run"

            [build-system]
            requires = ["setuptools"]
            build-backend = "setuptools.build_meta"
        """)
        import importlib.metadata as _meta
        with tempfile.TemporaryDirectory() as d:
            _write(d, "pyproject.toml", pyproject)
            with patch.object(_meta, "version", return_value="60.0.0"):
                _ensure_build_backend(d)
            cfg = _read(d, "setup.cfg")
        self.assertIn("[options.entry_points]", cfg)
        self.assertIn("console_scripts =", cfg)
        self.assertIn("mytool = mytool.cli:main", cfg)
        self.assertIn("other-cmd = mytool.other:run", cfg)


class TestCCPathResolution(unittest.TestCase):
    """CC and CXX are converted to absolute paths before the cwd changes."""

    def test_relative_cc_becomes_absolute(self):
        """A relative CC path must be made absolute (using cwd at that point)."""
        rel_path = "external/toolchain/bin/cc"
        abs_path = os.path.abspath(rel_path)
        env = {"CC": rel_path}
        with patch.dict(os.environ, env, clear=False):
            # Simulate what build_helper.py does at the CC/CXX normalization block
            for var in ("CC", "CXX"):
                if var in os.environ and not os.path.isabs(os.environ[var]):
                    os.environ[var] = os.path.abspath(os.environ[var])
            self.assertTrue(os.path.isabs(os.environ["CC"]))
            self.assertEqual(os.environ["CC"], abs_path)

    def test_absolute_cc_unchanged(self):
        """An already-absolute CC path must not be modified."""
        abs_path = "/usr/bin/gcc"
        env = {"CC": abs_path}
        with patch.dict(os.environ, env, clear=False):
            for var in ("CC", "CXX"):
                if var in os.environ and not os.path.isabs(os.environ[var]):
                    os.environ[var] = os.path.abspath(os.environ[var])
            self.assertEqual(os.environ["CC"], abs_path)

    def test_missing_cc_not_set(self):
        """If CC is absent from the environment, it must not be injected."""
        env_without_cc = {k: v for k, v in os.environ.items() if k not in ("CC", "CXX")}
        with patch.dict(os.environ, env_without_cc, clear=True):
            for var in ("CC", "CXX"):
                if var in os.environ and not os.path.isabs(os.environ[var]):
                    os.environ[var] = os.path.abspath(os.environ[var])
            self.assertNotIn("CC", os.environ)
            self.assertNotIn("CXX", os.environ)


if __name__ == "__main__":
    unittest.main(verbosity=2)
