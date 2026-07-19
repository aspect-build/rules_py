"""Tests for detect_native.py sdist configure tool."""

import io
import os
import sys
import tarfile
import tempfile
import zipfile
from collections.abc import Mapping

from uv.private.sdist_configure.detect_native import detect


def _make_tar_gz(members: Mapping[str, str | None]) -> str:
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


def _make_zip(members: Mapping[str, str | None]) -> str:
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


def test_pure_python() -> None:
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


def test_c_extension() -> None:
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


def test_headers_only_not_native() -> None:
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


def test_cython() -> None:
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


def test_rust() -> None:
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/src/lib.rs": "fn main() {}",
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    assert "setuptools_rust" in result["inferred_build_requires"]


# --- pyproject.toml parsing ---


def test_pyproject_build_requires() -> None:
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


def test_pyproject_degrades_without_tomllib() -> None:
    """On a pre-3.11 interpreter, pyproject parsing is skipped with a warning
    while the rest of the tool (native detection etc.) keeps working."""
    from uv.private.sdist_configure import detect_native
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pyproject.toml": '[build-system]\nrequires = ["cython"]\n',
        "pkg-1.0/pkg/fast.pyx": "# cython source",
    })
    saved = detect_native.tomllib
    detect_native.tomllib = None
    try:
        result = detect(archive, {})
    finally:
        detect_native.tomllib = saved
    assert result["build_requires"] == []
    assert result["is_native"] is True


# --- setup.cfg parsing ---


def test_setup_cfg_build_requires() -> None:
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


def test_legacy_setup_py_infers_setuptools() -> None:
    """A setup.py-only package (no pyproject.toml) gets setuptools+wheel inferred."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": "from setuptools import setup; setup()",
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "setuptools" in result["build_requires"]
    assert "wheel" in result["build_requires"]


def test_pyproject_does_not_infer_setuptools() -> None:
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


def test_extra_deps_resolved_from_available() -> None:
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


def test_extra_deps_excludes_already_provided() -> None:
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


def test_extra_deps_unresolvable_not_included() -> None:
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


def test_inferred_deps_in_extra_deps() -> None:
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


def test_zip_archive() -> None:
    archive = _make_zip({
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/ext.c": "/* C */",
    })
    result = detect(archive, {})
    assert result["is_native"] is True
    assert "pkg-1.0/pkg/ext.c" in result["native_files"]


def test_zip_archive_with_pyproject() -> None:
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


def test_flat_archive() -> None:
    """Some archives don't have a top-level directory prefix."""
    archive = _make_tar_gz({
        "pyproject.toml": '[build-system]\nrequires = ["flit_core"]\nbuild-backend = "flit_core.buildapi"\n',
        "pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "flit_core" in result["build_requires"]


# --- sdist console scripts ---


def test_console_scripts_from_egg_info() -> None:
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg.egg-info/entry_points.txt": (
            "[console_scripts]\n"
            "Upper-Case = pkg.cli:main [speedups] # legacy extra\n"
            "plain=pkg:run\n"
            "../escape = pkg.cli:main\n"
            "bad name = pkg.cli:main\n"
            "missing-target = pkg.cli\n"
            "extra-colon = pkg.cli:main:other\n"
            "stray-close = pkg.cli:main]\n"
            "stray-open = pkg.cli:main[extra\n"
            "[gui_scripts]\n"
            "ignored = pkg.gui:main\n"
        ),
    })
    result = detect(archive, {})
    assert result["console_scripts"] == [
        "Upper-Case=pkg.cli:main",
        "plain=pkg:run",
    ]


def test_console_scripts_from_flat_zip_archive() -> None:
    archive = _make_zip({
        "pkg/__init__.py": "",
        "pkg.egg-info/entry_points.txt": (
            "[console_scripts]\n"
            "percent = pkg.cli:run_%s\n"
        ),
    })
    result = detect(archive, {})
    assert result["console_scripts"] == ["percent=pkg.cli:run_%s"]


def test_console_scripts_preserve_prefixed_archive_member_names() -> None:
    members = {
        "./pkg-1.0/pkg/__init__.py": "",
        "./pkg-1.0/pkg.egg-info/entry_points.txt": (
            "[console_scripts]\nprefixed = pkg.cli:main\n"
        ),
    }
    for make_archive in (_make_tar_gz, _make_zip):
        assert detect(make_archive(members), {})["console_scripts"] == [
            "prefixed=pkg.cli:main",
        ]


def test_console_scripts_ignore_nested_and_ambiguous_egg_info() -> None:
    nested = _make_tar_gz({
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/vendor/dependency.egg-info/entry_points.txt": (
            "[console_scripts]\nvendor = dependency:main\n"
        ),
    })
    assert detect(nested, {})["console_scripts"] == []

    flat_nested = _make_tar_gz({
        "pkg/__init__.py": "",
        "vendor/PKG-INFO": "Metadata-Version: 2.1\nName: dependency\nVersion: 1.0\n",
        "vendor/dependency.egg-info/entry_points.txt": (
            "[console_scripts]\nvendor = dependency:main\n"
        ),
    })
    assert detect(flat_nested, {})["console_scripts"] == []

    ambiguous = _make_tar_gz({
        "pkg-1.0/PKG-INFO": "Metadata-Version: 2.1\nName: pkg\nVersion: 1.0\n",
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/src/pkg.egg-info/entry_points.txt": (
            "[console_scripts]\nfirst = pkg:first\n"
        ),
        "pkg-1.0/lib/pkg.egg-info/entry_points.txt": (
            "[console_scripts]\nsecond = pkg:second\n"
        ),
    })
    assert detect(ambiguous, {})["console_scripts"] == []


def test_console_scripts_from_distribution_owned_nested_egg_info() -> None:
    rooted = _make_tar_gz({
        "pkg-1.0/PKG-INFO": "Metadata-Version: 2.1\nName: pkg-name\nVersion: 1.0\n",
        "pkg-1.0/src/pkg/__init__.py": "",
        "pkg-1.0/src/Pkg_Name.egg-info/entry_points.txt": (
            "[console_scripts]\nrooted = pkg.cli:main\n"
        ),
        "pkg-1.0/vendor/other.egg-info/entry_points.txt": (
            "[console_scripts]\nvendor = other:main\n"
        ),
    })
    assert detect(rooted, {})["console_scripts"] == [
        "rooted=pkg.cli:main",
    ]

    prefixed_zip = _make_zip({
        "./pkg-1.0/PKG-INFO": "Metadata-Version: 2.1\nName: pkg_name\nVersion: 1.0\n",
        "./pkg-1.0/lib/pkg/__init__.py": "",
        "./pkg-1.0/lib/pkg-name.egg-info/entry_points.txt": (
            "[console_scripts]\nlib = pkg.cli:main\n"
        ),
        "./pkg-1.0/vendor/other.egg-info/entry_points.txt": (
            "[console_scripts]\nvendor = other:main\n"
        ),
    })
    assert detect(prefixed_zip, {})["console_scripts"] == [
        "lib=pkg.cli:main",
    ]

    flat = _make_tar_gz({
        "./PKG-INFO": "Metadata-Version: 2.1\nName: pkg\nVersion: 1.0\n",
        "./src/pkg/__init__.py": "",
        "./src/pkg.egg-info/entry_points.txt": (
            "[console_scripts]\nflat = pkg.cli:main\n"
        ),
        "./vendor/other.egg-info/entry_points.txt": (
            "[console_scripts]\nvendor = other:main\n"
        ),
    })
    assert detect(flat, {})["console_scripts"] == [
        "flat=pkg.cli:main",
    ]


# --- setup.py partial evaluator ---


def test_setup_py_literal_setup_requires() -> None:
    """setup_requires as a literal list in setup()."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'setup(\n'
            '    name="pkg",\n'
            '    setup_requires=["cython>=0.29", "numpy"],\n'
            '    install_requires=["requests>=2.0"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    # setup_requires should appear in build_requires
    assert "cython" in result["build_requires"]
    assert "numpy" in result["build_requires"]
    # install_requires reported separately
    assert "requests" in result["setup_py_install_requires"]


def test_setup_py_variable_reference() -> None:
    """setup_requires referencing a variable defined earlier."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'BUILD_DEPS = ["cython", "numpy>=1.20"]\n'
            'setup(\n'
            '    name="pkg",\n'
            '    setup_requires=BUILD_DEPS,\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "cython" in result["build_requires"]
    assert "numpy" in result["build_requires"]


def test_setup_py_list_concatenation() -> None:
    """setup_requires built from list concatenation."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'BASE = ["setuptools"]\n'
            'EXTRA = ["cython"]\n'
            'setup(\n'
            '    name="pkg",\n'
            '    setup_requires=BASE + EXTRA,\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "setuptools" in result["build_requires"]
    assert "cython" in result["build_requires"]


def test_setup_py_setuptools_dot_setup() -> None:
    """setuptools.setup() call syntax."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'import setuptools\n'
            'setuptools.setup(\n'
            '    name="pkg",\n'
            '    setup_requires=["cython"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "cython" in result["build_requires"]


def test_setup_py_dynamic_deps() -> None:
    """Dynamic deps computed at runtime are captured by exec."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'deps = ["numpy"]\n'
            'if True:\n'
            '    deps.append("scipy")\n'
            'setup(\n'
            '    name="pkg",\n'
            '    install_requires=deps,\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "numpy" in result["setup_py_install_requires"]
    assert "scipy" in result["setup_py_install_requires"]


def test_setup_py_imports_own_package() -> None:
    """setup.py that imports the package (e.g. for __version__) doesn't crash."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'from mypackage import __version__\n'
            'setup(\n'
            '    name="pkg",\n'
            '    version=str(__version__),\n'
            '    setup_requires=["cython"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "cython" in result["build_requires"]


def test_setup_py_distutils_setup() -> None:
    """distutils.core.setup() call syntax."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from distutils.core import setup\n'
            'setup(\n'
            '    name="pkg",\n'
            '    install_requires=["requests"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "requests" in result["setup_py_install_requires"]


def test_setup_py_syntax_error_graceful() -> None:
    """A setup.py with syntax errors should not crash detection."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": "this is not valid python }{][",
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert result["setup_py_setup_requires"] == []
    assert result["setup_py_install_requires"] == []


def test_setup_py_exception_graceful() -> None:
    """A setup.py that raises during exec should not crash detection."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'raise RuntimeError("I am broken")\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert result["setup_py_setup_requires"] == []
    assert result["setup_py_install_requires"] == []


def test_setup_py_setup_requires_in_extra_deps() -> None:
    """setup.py setup_requires should feed into extra_deps resolution."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'setup(\n'
            '    name="pkg",\n'
            '    setup_requires=["cython", "numpy>=1.20"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    context = {
        "deps": [],
        "available_deps": {
            "cython": "@pypi//cython:install",
            "numpy": "@pypi//numpy:install",
            "setuptools": "@pypi//setuptools:install",
        },
    }
    result = detect(archive, context)
    assert "cython" in result["extra_deps"]
    assert "numpy" in result["extra_deps"]


def test_setup_py_main_guard() -> None:
    """setup.py with if __name__ == '__main__' guard."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'if __name__ == "__main__":\n'
            '    setup(\n'
            '        name="pkg",\n'
            '        setup_requires=["cython"],\n'
            '        install_requires=["numpy"],\n'
            '    )\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "cython" in result["build_requires"]
    assert "numpy" in result["setup_py_install_requires"]


def test_setup_py_distutils_qualified_call() -> None:
    """distutils.core.setup() via qualified attribute access (not from-import)."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'import distutils.core\n'
            'distutils.core.setup(\n'
            '    name="pkg",\n'
            '    install_requires=["requests"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "requests" in result["setup_py_install_requires"]


def test_setup_py_file_io_failure_graceful() -> None:
    """setup.py that reads a nonexistent file before calling setup()."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'with open("NONEXISTENT_FILE_d41d8cd98f00b204.txt") as f:\n'
            '    long_description = f.read()\n'
            'setup(\n'
            '    name="pkg",\n'
            '    long_description=long_description,\n'
            '    install_requires=["requests"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    # FileNotFoundError before setup() is called — deps are lost
    assert result["setup_py_setup_requires"] == []
    assert result["setup_py_install_requires"] == []


def test_setup_py_never_calls_setup() -> None:
    """setup.py that imports setuptools but never calls setup()."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'x = 42\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert result["setup_py_setup_requires"] == []
    assert result["setup_py_install_requires"] == []


def test_setup_py_sys_exit_graceful() -> None:
    """setup.py that calls sys.exit() should not crash detection."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'import sys\n'
            'sys.exit("Python 2 only")\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert result["setup_py_setup_requires"] == []
    assert result["setup_py_install_requires"] == []


def test_setup_py_platform_conditional() -> None:
    """setup.py using platform.system() for conditional deps."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'import platform\n'
            'from setuptools import setup\n'
            'deps = ["requests"]\n'
            'if platform.system() == "Linux":\n'
            '    deps.append("pyinotify")\n'
            'setup(\n'
            '    name="pkg",\n'
            '    install_requires=deps,\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "requests" in result["setup_py_install_requires"]
    # pyinotify presence depends on the platform running the test,
    # but the point is it doesn't crash


def test_setup_py_pkg_resources_import() -> None:
    """setup.py importing pkg_resources — handled by mock import system."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from pkg_resources import get_distribution\n'
            'from setuptools import setup\n'
            'setup(\n'
            '    name="pkg",\n'
            '    install_requires=["requests"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert "requests" in result["setup_py_install_requires"]


def test_setup_py_chdir_restored() -> None:
    """setup.py that calls os.chdir() — cwd should be restored."""
    original_cwd = os.getcwd()
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'import os\n'
            'os.chdir("/tmp")\n'
            'from setuptools import setup\n'
            'setup(name="pkg", install_requires=["requests"])\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert os.getcwd() == original_cwd
    assert "requests" in result["setup_py_install_requires"]


def test_setup_py_sys_path_restored() -> None:
    """setup.py that mutates sys.path — should be restored."""
    original_path = sys.path[:]
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'import sys\n'
            'sys.path.insert(0, "/bogus/path")\n'
            'from setuptools import setup\n'
            'setup(name="pkg", install_requires=["requests"])\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    assert sys.path == original_path
    assert "requests" in result["setup_py_install_requires"]


def test_setup_py_extension_with_install_requires() -> None:
    """setup.py with Extension() objects and install_requires."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.py": (
            'from setuptools import setup, Extension\n'
            'ext = Extension("pkg._accel", sources=["pkg/_accel.c"])\n'
            'setup(\n'
            '    name="pkg",\n'
            '    ext_modules=[ext],\n'
            '    install_requires=["numpy>=1.20"],\n'
            '    setup_requires=["cython"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
        "pkg-1.0/pkg/_accel.c": "/* C */",
    })
    result = detect(archive, {})
    assert "numpy" in result["setup_py_install_requires"]
    assert "cython" in result["build_requires"]


def test_setup_cfg_and_setup_py_merged() -> None:
    """Both setup.cfg and setup.py providing different deps — should merge."""
    archive = _make_tar_gz({
        "pkg-1.0/": None,
        "pkg-1.0/setup.cfg": (
            '[options]\n'
            'setup_requires =\n'
            '    numpy\n'
        ),
        "pkg-1.0/setup.py": (
            'from setuptools import setup\n'
            'setup(\n'
            '    name="pkg",\n'
            '    setup_requires=["cython"],\n'
            ')\n'
        ),
        "pkg-1.0/pkg/__init__.py": "",
    })
    result = detect(archive, {})
    # Both sources should contribute to build_requires
    assert "numpy" in result["build_requires"]
    assert "cython" in result["build_requires"]


if __name__ == "__main__":
    failures = []
    test_fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in test_fns:
        try:
            fn()
            print(f"  PASS  {fn.__name__}")
        except Exception as e:
            print(f"  FAIL  {fn.__name__}: {e}")
            failures.append(fn.__name__)

    total = len(test_fns)
    passed = total - len(failures)
    print(f"\n{passed} passed, {len(failures)} failed (of {total})")
    if failures:
        print(f"Failures: {', '.join(failures)}")
        sys.exit(1)
