"""Unit tests for build_backend.ensure_build_backend."""

import os
import sys
import tempfile

from uv.private.pep517_whl.build_backend import ensure_build_backend


def _make_project(members):
    """Write a dict of {relative_path: content} into a temp directory."""
    d = tempfile.mkdtemp()
    for rel, content in members.items():
        full = os.path.join(d, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(content)
    return d


def _read(d, rel):
    with open(os.path.join(d, rel)) as f:
        return f.read()


def _pyproject(backend, name="pkg", version="1.0"):
    return (
        "[project]\n"
        'name = "{}"\n'
        'version = "{}"\n'
        "\n"
        "[build-system]\n"
        'requires = ["{}"]'
        '\nbuild-backend = "{}"\n'
    ).format(name, version, backend.split(":")[0].split(".")[0], backend)


# ---------------------------------------------------------------------------
# Available backend — no mutation
# ---------------------------------------------------------------------------

def test_available_backend_not_mutated():
    """When the declared backend is importable, pyproject.toml is left alone."""
    original = _pyproject("setuptools.build_meta")
    d = _make_project({"pyproject.toml": original})
    ensure_build_backend(d)
    assert _read(d, "pyproject.toml") == original


# ---------------------------------------------------------------------------
# Unavailable backend — fallback to setuptools
# ---------------------------------------------------------------------------

def test_unavailable_backend_rewritten():
    """A non-importable backend causes pyproject.toml to be rewritten."""
    d = _make_project({"pyproject.toml": _pyproject("_nonexistent_backend_xyz_")})
    ensure_build_backend(d)
    content = _read(d, "pyproject.toml")
    assert 'build-backend = "setuptools.build_meta"' in content
    assert "_nonexistent_backend_xyz_" not in content


def test_unavailable_backend_preserves_project_section():
    """Rewriting build-system must not strip the [project] table."""
    d = _make_project({"pyproject.toml": _pyproject("_nonexistent_backend_xyz_", name="mypkg", version="2.3")})
    ensure_build_backend(d)
    content = _read(d, "pyproject.toml")
    assert "[project]" in content
    assert 'name = "mypkg"' in content
    assert 'version = "2.3"' in content


# ---------------------------------------------------------------------------
# No pyproject.toml — no-op
# ---------------------------------------------------------------------------

def test_no_pyproject_is_noop():
    d = tempfile.mkdtemp()
    ensure_build_backend(d)  # must not raise


# ---------------------------------------------------------------------------
# setup.cfg generation for old setuptools (mocked via monkeypatching)
# ---------------------------------------------------------------------------

def test_setup_cfg_generated_for_old_setuptools(monkeypatch=None):
    """When setuptools < 61, a setup.cfg is generated from [project] metadata."""
    import importlib.metadata
    import uv.private.pep517_whl.build_backend as mod

    original_version = importlib.metadata.version

    def fake_version(name):
        if name == "setuptools":
            return "60.0.0"
        return original_version(name)

    mod_metadata = mod.importlib.metadata
    orig = mod_metadata.version
    mod_metadata.version = fake_version
    try:
        d = _make_project({"pyproject.toml": _pyproject("setuptools.build_meta", name="mypkg", version="3.1")})
        ensure_build_backend(d)
        assert os.path.exists(os.path.join(d, "setup.cfg"))
        cfg = _read(d, "setup.cfg")
        assert "name = mypkg" in cfg
        assert "version = 3.1" in cfg
    finally:
        mod_metadata.version = orig


def test_setup_cfg_not_generated_for_new_setuptools():
    """When setuptools >= 61, setup.cfg is NOT generated."""
    d = _make_project({"pyproject.toml": _pyproject("setuptools.build_meta", name="mypkg", version="1.0")})
    ensure_build_backend(d)
    assert not os.path.exists(os.path.join(d, "setup.cfg"))


def test_existing_setup_cfg_not_overwritten():
    """An existing setup.cfg must never be overwritten."""
    import importlib.metadata
    import uv.private.pep517_whl.build_backend as mod

    original_content = "[metadata]\nname = original\n"
    mod_metadata = mod.importlib.metadata
    orig = mod_metadata.version
    mod_metadata.version = lambda n: "60.0.0" if n == "setuptools" else orig(n)
    try:
        d = _make_project({
            "pyproject.toml": _pyproject("setuptools.build_meta", name="mypkg", version="1.0"),
            "setup.cfg": original_content,
        })
        ensure_build_backend(d)
        assert _read(d, "setup.cfg") == original_content
    finally:
        mod_metadata.version = orig


# ---------------------------------------------------------------------------
# [project.scripts] propagated into setup.cfg entry_points
# ---------------------------------------------------------------------------

def test_scripts_in_setup_cfg(monkeypatch=None):
    import uv.private.pep517_whl.build_backend as mod

    pyproject = (
        '[project]\nname = "cli"\nversion = "1.0"\n\n'
        '[project.scripts]\ncli-tool = "cli.main:main"\n\n'
        '[build-system]\nrequires = ["setuptools"]\nbuild-backend = "setuptools.build_meta"\n'
    )
    mod_metadata = mod.importlib.metadata
    orig = mod_metadata.version
    mod_metadata.version = lambda n: "60.0.0" if n == "setuptools" else orig(n)
    try:
        d = _make_project({"pyproject.toml": pyproject})
        ensure_build_backend(d)
        cfg = _read(d, "setup.cfg")
        assert "console_scripts" in cfg
        assert "cli-tool" in cfg
    finally:
        mod_metadata.version = orig


if __name__ == "__main__":
    failures = []
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        try:
            fn()
            print("  PASS  {}".format(fn.__name__))
        except Exception as e:
            print("  FAIL  {}: {}".format(fn.__name__, e))
            failures.append(fn.__name__)
    print("\n{} passed, {} failed".format(len(fns) - len(failures), len(failures)))
    if failures:
        sys.exit(1)
