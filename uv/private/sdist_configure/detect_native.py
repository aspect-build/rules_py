#!/usr/bin/env python3

"""Default sdist configure tool for aspect_rules_py.

Inspects a source distribution archive and reports:
- Whether it contains native/compiled source files
- Build dependencies declared in pyproject.toml / setup.cfg
- Additional deps that should be resolved from the lockfile

See //uv/private/sdist_configure:defs.bzl for the full interface contract.

Requires Python >= 3.11 (for tomllib).
"""

import configparser
import importlib
import os
import importlib.abc
import importlib.machinery
import json
import re
import sys
import tarfile
import tempfile
import types
import zipfile

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None
from pathlib import PurePosixPath

NATIVE_EXTENSIONS = frozenset({
    ".c",
    ".cc", ".cpp", ".cxx",
    ".pyx", ".pxd",
    ".rs",
    ".s", ".asm",
})

EXTENSION_TO_BUILD_DEP = {
    ".pyx": "cython",
    ".pxd": "cython",
    ".rs": "setuptools-rust",
}

_REQ_NAME_RE = re.compile(r"^([A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?)")


def _normalize_name(name):
    """Normalize a Python package name (PEP 503)."""
    return re.sub(r"[-_.]+", "_", name).lower()


def _extract_name(requirement_str):
    """Extract the normalized package name from a PEP 508 requirement string."""
    m = _REQ_NAME_RE.match(requirement_str.strip())
    if m:
        return _normalize_name(m.group(1))
    return None


def _read_tar_member(tf, member_name):
    try:
        f = tf.extractfile(tf.getmember(member_name))
        return f.read().decode("utf-8", errors="replace") if f else None
    except (KeyError, tarfile.TarError):
        return None


def _read_zip_member(zf, member_name):
    try:
        return zf.read(member_name).decode("utf-8", errors="replace")
    except KeyError:
        return None


def _open_archive(path):
    if zipfile.is_zipfile(path):
        zf = zipfile.ZipFile(path, "r")
        members = [i.filename for i in zf.infolist() if not i.is_dir()]
        return members, lambda name: _read_zip_member(zf, name), zf.close

    tf = tarfile.open(path, "r:*")
    members = [m.name for m in tf.getmembers() if m.isfile()]
    return members, lambda name: _read_tar_member(tf, name), tf.close



def _parse_pyproject_build_system(content):
    """Extract [build-system] metadata from pyproject.toml content.

    Returns (requires, build_backend, backend_path) where:
    - requires: list of normalized package names
    - build_backend: the build-backend string (e.g. "setuptools.build_meta"), or None
    - backend_path: the backend-path list, or None
    """
    if tomllib is None:
        return [], None, None
    data = tomllib.loads(content)
    build_system = data.get("build-system", {})
    requires = [
        _extract_name(r)
        for r in build_system.get("requires", [])
        if _extract_name(r)
    ]
    build_backend = build_system.get("build-backend")
    backend_path = build_system.get("backend-path")
    return requires, build_backend, backend_path


def _parse_setup_cfg_build_requires(content):
    """Extract [options] setup_requires from setup.cfg content."""
    parser = configparser.ConfigParser()
    parser.read_string(content)
    raw = parser.get("options", "setup_requires", fallback="")
    if not raw:
        return []
    return [
        _extract_name(line.strip())
        for line in raw.strip().splitlines()
        if _extract_name(line.strip())
    ]


class _SetupCapture(BaseException):
    """Raised by our fake setup() to abort execution after capturing kwargs.

    Inherits from BaseException (not Exception) so that setup.py files
    with ``except Exception:`` blocks don't accidentally swallow it.
    """


class _MockModule(types.ModuleType):
    """A module that returns mock objects for any attribute access.

    Prevents ImportError for packages that aren't installed in the
    analysis environment (which is most of them).
    """

    def __init__(self, name):
        super().__init__(name)
        self.__path__ = []
        self.__file__ = f"<mock:{name}>"

    def __getattr__(self, name):
        if name in ("__path__", "__file__", "__name__", "__loader__", "__spec__"):
            return super().__getattribute__(name)
        # Return a new mock module for sub-attribute access
        child = _MockModule(f"{self.__name__}.{name}")
        setattr(self, name, child)
        return child

    def __call__(self, *args, **kwargs):
        return _MockModule(f"{self.__name__}()")

    def __iter__(self):
        return iter([])

    def __bool__(self):
        return False

    def __str__(self):
        return ""

    def __repr__(self):
        return f"<mock:{self.__name__}>"


class _MockImportLoader(importlib.abc.Loader):
    """Loader that creates mock modules."""

    def create_module(self, spec):
        return _MockModule(spec.name)

    def exec_module(self, module):
        pass  # MockModule handles everything via __getattr__


class _MockImportFinder(importlib.abc.MetaPathFinder):
    """Import hook that returns mock modules for anything not in stdlib.

    Installed at the front of sys.meta_path during setup.py execution so
    that `from mypackage import __version__` and similar don't blow up.
    """

    _loader = _MockImportLoader()

    # Modules we allow to import normally (stdlib + stuff we need).
    _PASSTHROUGH = frozenset({
        "os", "os.path", "sys", "re", "io", "codecs", "pathlib",
        "platform", "struct", "collections", "functools", "itertools",
        "contextlib", "warnings", "errno", "stat", "posixpath",
        "ntpath", "genericpath", "fnmatch", "glob", "operator",
        "string", "textwrap", "copy", "types", "abc",
        "configparser", "json",
    })

    def find_spec(self, fullname, path, target=None):
        if fullname in self._PASSTHROUGH or fullname in sys.modules:
            return None
        top = fullname.split(".")[0]
        if top in self._PASSTHROUGH:
            return None
        return importlib.machinery.ModuleSpec(
            fullname, self._loader, is_package=True,
        )


def _parse_setup_py_requires(content):
    """Extract setup_requires and install_requires from setup.py via exec.

    Executes the setup.py with a fake setup() that captures its keyword
    arguments, and a mock import system that prevents ImportErrors.

    Args:
        content: The setup.py source code as a string.

    Returns:
        (setup_requires, install_requires) where each is a list of
        normalized package names. Returns empty lists on failure.
    """
    captured = {}

    def _fake_setup(*args, **kwargs):
        captured.update(kwargs)
        raise _SetupCapture()

    fake_setuptools = _MockModule("setuptools")
    fake_setuptools.setup = _fake_setup
    fake_setuptools.find_packages = lambda *a, **kw: []
    fake_setuptools.find_namespace_packages = lambda *a, **kw: []
    fake_setuptools.Extension = lambda *a, **kw: None

    fake_distutils = _MockModule("distutils")
    fake_distutils_core = _MockModule("distutils.core")
    fake_distutils_core.setup = _fake_setup
    fake_distutils.core = fake_distutils_core

    old_meta_path = sys.meta_path[:]
    old_modules = sys.modules.copy()
    old_argv = sys.argv[:]
    old_path = sys.path[:]
    old_cwd = os.getcwd()

    finder = _MockImportFinder()
    failed = False

    stdout_tmp = tempfile.TemporaryFile(mode="w+")
    stderr_tmp = tempfile.TemporaryFile(mode="w+")
    old_stdout = sys.stdout
    old_stderr = sys.stderr

    try:
        sys.meta_path.insert(0, finder)
        sys.modules["setuptools"] = fake_setuptools
        sys.modules["distutils"] = fake_distutils
        sys.modules["distutils.core"] = fake_distutils_core
        sys.argv = ["setup.py"]
        sys.stdout = stdout_tmp
        sys.stderr = stderr_tmp

        globs = {
            "__name__": "__main__",
            "__file__": "setup.py",
            "__builtins__": __builtins__,
            "setup": _fake_setup,
        }

        exec(compile(content, "setup.py", "exec"), globs)
    except _SetupCapture:
        pass
    except BaseException:
        failed = True
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr
        sys.argv = old_argv
        sys.path[:] = old_path
        sys.meta_path[:] = old_meta_path
        try:
            os.chdir(old_cwd)
        except OSError:
            pass
        for name in list(sys.modules):
            if name not in old_modules:
                del sys.modules[name]
        sys.modules.update(old_modules)

        if failed:
            for tmp, dest in ((stdout_tmp, old_stderr), (stderr_tmp, old_stderr)):
                tmp.seek(0)
                data = tmp.read()
                if data:
                    dest.write(data)
        stdout_tmp.close()
        stderr_tmp.close()

    if failed:
        return [], []

    def _extract_names(key):
        value = captured.get(key)
        if not isinstance(value, (list, tuple)):
            return []
        return [
            _extract_name(item)
            for item in value
            if isinstance(item, str) and _extract_name(item)
        ]

    setup_requires = _extract_names("setup_requires")
    install_requires = _extract_names("install_requires")
    return setup_requires, install_requires


def _find_config_file(members, filename):
    """Find a config file, accounting for the typical top-level sdist directory."""
    if filename in members:
        return filename
    for m in members:
        parts = PurePosixPath(m).parts
        if len(parts) == 2 and parts[1] == filename:
            return m
    return None


def detect(archive_path, context):
    """Run detection on an sdist archive.

    Args:
        archive_path: Path to the archive file.
        context: Build context dict (from context JSON), or empty dict.

    Returns:
        Result dict conforming to the sdist configure output schema.
    """
    members, read_fn, close_fn = _open_archive(archive_path)
    try:
        native_files = []
        seen_extensions = set()
        for name in members:
            suffix = PurePosixPath(name).suffix.lower()
            if suffix in NATIVE_EXTENSIONS:
                native_files.append(name)
                seen_extensions.add(suffix)

        inferred = set()
        for ext in seen_extensions:
            dep = EXTENSION_TO_BUILD_DEP.get(ext)
            if dep:
                inferred.add(_normalize_name(dep))

        declared = []
        build_backend = None
        backend_path = None

        pyproject_path = _find_config_file(members, "pyproject.toml")
        if pyproject_path:
            content = read_fn(pyproject_path)
            if content:
                requires, build_backend, backend_path = _parse_pyproject_build_system(content)
                declared.extend(requires)

        setup_cfg_path = _find_config_file(members, "setup.cfg")
        if setup_cfg_path:
            content = read_fn(setup_cfg_path)
            if content:
                declared.extend(_parse_setup_cfg_build_requires(content))

        setup_py_path = _find_config_file(members, "setup.py")
        has_setup_py = setup_py_path is not None
        setup_py_setup_requires = []
        setup_py_install_requires = []
        if setup_py_path:
            setup_py_content = read_fn(setup_py_path)
            if setup_py_content:
                setup_py_setup_requires, setup_py_install_requires = (
                    _parse_setup_py_requires(setup_py_content)
                )
                declared.extend(setup_py_setup_requires)
    finally:
        close_fn()

    if not pyproject_path and has_setup_py:
        if "setuptools" not in {_normalize_name(d) for d in declared}:
            declared.append("setuptools")
        if "wheel" not in {_normalize_name(d) for d in declared}:
            declared.append("wheel")

    seen = set()
    declared_dedup = []
    for name in declared:
        if name not in seen:
            seen.add(name)
            declared_dedup.append(name)

    available_deps = context.get("available_deps", {})
    provided_labels = set(context.get("deps", []))

    all_discovered = set(declared_dedup) | inferred
    extra_deps = sorted(
        name for name in all_discovered
        if name in available_deps
        and available_deps[name] not in provided_labels
    )

    result = {
        "is_native": bool(native_files),
        "native_files": native_files,
        "build_requires": declared_dedup,
        "inferred_build_requires": sorted(inferred),
        "extra_deps": extra_deps,
        "build_backend": build_backend,
        "has_pyproject": pyproject_path is not None,
        "has_setup_py": has_setup_py,
        "has_setup_cfg": setup_cfg_path is not None,
        "setup_py_setup_requires": setup_py_setup_requires,
        "setup_py_install_requires": setup_py_install_requires,
    }
    if backend_path is not None:
        result["backend_path"] = backend_path
    return result


def main():
    if len(sys.argv) not in (2, 3):
        print(
            "Usage: detect_native.py <archive-path> [<context-json-path>]",
            file=sys.stderr,
        )
        sys.exit(1)

    archive_path = sys.argv[1]
    context = {}
    if len(sys.argv) == 3:
        with open(sys.argv[2]) as f:
            context = json.load(f)

    try:
        result = detect(archive_path, context)
    except Exception as e:
        print(f"Error inspecting {archive_path}: {e}", file=sys.stderr)
        sys.exit(1)

    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
