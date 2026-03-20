"""Tests for detect_native.py sdist configure tool."""

import io
import json
import os
import sys
import tarfile
import tempfile
import zipfile

from uv.private.sdist_configure.detect_native import detect

try:
    import tomllib
    HAS_TOMLLIB = True
except ModuleNotFoundError:
    HAS_TOMLLIB = False


class _Skip(Exception):
    """Raised to skip a test."""


def requires_tomllib(fn):
    """Skip test if tomllib is not available (Python < 3.11)."""
    def wrapper():
        if not HAS_TOMLLIB:
            raise _Skip("requires Python >= 3.11 (tomllib)")
        return fn()
    wrapper.__name__ = fn.__name__
    return wrapper


def _make_tar_gz(members):
    """Create a .tar.gz archive in a temp file from a dict of {name: content}.

    Content may be a string (file) or None (directory).
    Returns the path to the archive.
    """
    path = os.path.join(tempfile.mkdtemp(), "pkg-1.0.tar.gz")
    with tarfile.open(path, "w:gz") as tf:
        for name, content in members.items():
            info = tarfile.TarInfo(name=name)
            if content is None:
                info.type = tarfile.DIRTYPE
                tf.addfile(info)
            else:
                data = content.encode("utf-8")
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
    return path


def _make_zip(members):
    """Create a .zip archive in a temp file from a dict of {name: content}.

    Returns the path to the archive.
    """
    path = os.path.join(tempfile.mkdtemp(), "pkg-1.0.zip")
    with zipfile.ZipFile(path, "w") as zf:
        for name, content in members.items():
            if content is not None:
                zf.writestr(name, content)
    return path


# --- Pure Python ---


def test_pure_python():
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": "from setuptools import setup; setup()",
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/main.py": "print('hello')",
    })
    result = detect(archive, {})
    assert result["is_native"] is False
    assert result["native_files"] == []
    assert result["extra_deps"] == []


# --- C extension ---


def test_c_extension():
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/_accel.c": "/* C source */",
        "pkg-1.0/pkg/_accel.h": "/* C header */",
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    # Headers alone don't count — only .c triggers native
    assert result["native_files"] == ["pkg-1.0/pkg/_accel.c"]
    assert result["inferred_build_requires"] == []


def test_headers_only_not_native():
    """Packages with only .h/.hpp files are not considered native."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/types.h": "/* header */",
        "pkg-1.0/pkg/utils.hpp": "/* header */",
    })
    result = detect(archive, {})
    assert result["is_native"] is False
    assert result["native_files"] == []


# --- Cython ---


def test_cython():
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/fast.pyx": "# cython source",
        "pkg-1.0/pkg/fast.pxd": "# cython decl",
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    assert "cython" in result["inferred_build_requires"]


# --- Rust ---


def test_rust():
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/src/lib.rs": "fn main() {}",
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    assert "setuptools_rust" in result["inferred_build_requires"]


# --- pyproject.toml parsing ---


@requires_tomllib
def test_pyproject_build_requires():
    pyproject = """\
[build-system]
requires = ["setuptools>=68", "wheel", "cython>=3.0"]
build-backend = "setuptools.build_meta"
"""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pyproject.toml": pyproject,
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "setuptools" in result["build_requires"]
    assert "wheel" in result["build_requires"]
    assert "cython" in result["build_requires"]


# --- setup.cfg parsing ---


def test_setup_cfg_build_requires():
    setup_cfg = """\
[options]
setup_requires =
    setuptools
    numpy>=1.20
"""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.cfg": setup_cfg,
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "setuptools" in result["build_requires"]
    assert "numpy" in result["build_requires"]


# --- legacy setup.py fallback ---


def test_legacy_setup_py_infers_setuptools():
    """A setup.py-only package (no pyproject.toml) gets setuptools+wheel inferred."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": "from setuptools import setup; setup()",
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "setuptools" in result["build_requires"]
    assert "wheel" in result["build_requires"]


@requires_tomllib
def test_pyproject_does_not_infer_setuptools():
    """A package with pyproject.toml should NOT get implicit setuptools."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pyproject.toml": (
            '[build-system]\nrequires = ["flit_core"]\n'
            'build-backend = "flit_core.buildapi"\n'
        ),
        "pkg-1.0/setup.py": "# legacy shim",
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "setuptools" not in result["build_requires"]
    assert "flit_core" in result["build_requires"]


# --- extra_deps resolution ---


@requires_tomllib
def test_extra_deps_resolved_from_available():
    """Declared build deps that exist in available_deps become extra_deps."""
    pyproject = """\
[build-system]
requires = ["setuptools", "cython"]
build-backend = "setuptools.build_meta"
"""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pyproject.toml": pyproject,
        "pkg-1.0/pkg/__init__.py": "",
    })
    context = {
        "deps": [],
        "available_deps": {
            "setuptools": "@pypi//setuptools:install",
            "cython": "@pypi//cython:install",
        },
    }
    result = detect(archive, context)
    assert "setuptools" in result["extra_deps"]
    assert "cython" in result["extra_deps"]


@requires_tomllib
def test_extra_deps_excludes_already_provided():
    """Deps already in the explicit deps list are not reported as extra."""
    pyproject = """\
[build-system]
requires = ["setuptools", "cython"]
build-backend = "setuptools.build_meta"
"""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pyproject.toml": pyproject,
        "pkg-1.0/pkg/__init__.py": "",
    })
    context = {
        "deps": ["@pypi//setuptools:install"],
        "available_deps": {
            "setuptools": "@pypi//setuptools:install",
            "cython": "@pypi//cython:install",
        },
    }
    result = detect(archive, context)
    # setuptools is already provided, so only cython is extra
    assert "setuptools" not in result["extra_deps"]
    assert "cython" in result["extra_deps"]


@requires_tomllib
def test_extra_deps_unresolvable_not_included():
    """Deps not in available_deps are silently omitted from extra_deps."""
    pyproject = """\
[build-system]
requires = ["setuptools", "some-obscure-dep"]
build-backend = "setuptools.build_meta"
"""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pyproject.toml": pyproject,
        "pkg-1.0/pkg/__init__.py": "",
    })
    context = {
        "deps": [],
        "available_deps": {
            "setuptools": "@pypi//setuptools:install",
        },
    }
    result = detect(archive, context)
    assert "setuptools" in result["extra_deps"]
    assert "some_obscure_dep" not in result["extra_deps"]


# --- Inferred deps merged into extra_deps ---


def test_inferred_deps_in_extra_deps():
    """Extension-inferred deps (e.g. .pyx -> cython) show up in extra_deps."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pkg/fast.pyx": "# cython",
        "pkg-1.0/pkg/__init__.py": "",
    })
    context = {
        "deps": [],
        "available_deps": {
            "cython": "@pypi//cython:install",
        },
    }
    result = detect(archive, context)
    assert result["is_native"] is True
    assert "cython" in result["extra_deps"]


# --- Zip archive support ---


def test_zip_archive():
    archive = _make_zip({
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/ext.c": "/* C */",
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    assert "pkg-1.0/pkg/ext.c" in result["native_files"]


@requires_tomllib
def test_zip_archive_with_pyproject():
    archive = _make_zip({
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/ext.c": "/* C */",
        "pkg-1.0/pyproject.toml": (
            '[build-system]\nrequires = ["setuptools"]\n'
            'build-backend = "setuptools.build_meta"\n'
        ),
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    assert "setuptools" in result["build_requires"]


# --- Config files at root (no top-level directory) ---


@requires_tomllib
def test_flat_archive():
    """Some archives don't have a top-level directory prefix."""
    archive = _make_tar_gz({
        "pyproject.toml": '[build-system]\nrequires = ["flit_core"]\nbuild-backend = "flit_core.buildapi"\n',
        "pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "flit_core" in result["build_requires"]


if __name__ == "__main__":
    failures = []
    skipped = []
    test_fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in test_fns:
        try:
            fn()
            print(f"  PASS  {fn.__name__}")
        except _Skip as e:
            print(f"  SKIP  {fn.__name__}: {e}")
            skipped.append(fn.__name__)
        except Exception as e:
            print(f"  FAIL  {fn.__name__}: {e}")
            failures.append(fn.__name__)

    total = len(test_fns)
    passed = total - len(failures) - len(skipped)
    print(f"\n{passed} passed, {len(skipped)} skipped, {len(failures)} failed (of {total})")
    if failures:
        print(f"Failures: {', '.join(failures)}")
        sys.exit(1)
