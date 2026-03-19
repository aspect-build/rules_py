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
import json
import re
import sys
import tarfile
import zipfile

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None
from pathlib import PurePosixPath

# Extensions that indicate native/compiled source code.
# Headers (.h, .hpp, .hxx) are excluded — many packages ship headers without
# any actual compilable source (e.g. pyobjc framework stubs).
NATIVE_EXTENSIONS = frozenset({
    # C
    ".c",
    # C++
    ".cc", ".cpp", ".cxx",
    # Cython
    ".pyx", ".pxd",
    # Fortran
    ".f", ".f90", ".f95", ".for",
    # Rust
    ".rs",
    # Assembly
    ".s", ".asm",
})

# Map from file extensions to build-time package dependencies.
# Note: C/C++ extensions are handled natively by setuptools and don't need
# extra deps. Fortran has no reliable default build dep to infer.
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


# --- Archive helpers ---

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
    """Open an archive. Returns (members, reader_fn, closer)."""
    if zipfile.is_zipfile(path):
        zf = zipfile.ZipFile(path, "r")
        members = [i.filename for i in zf.infolist() if not i.is_dir()]
        return members, lambda name: _read_zip_member(zf, name), zf.close

    tf = tarfile.open(path, "r:*")
    members = [m.name for m in tf.getmembers() if m.isfile()]
    return members, lambda name: _read_tar_member(tf, name), tf.close


# --- Config file parsers ---

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


# --- Detection ---

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
        # Detect native source files
        native_files = []
        seen_extensions = set()
        for name in members:
            suffix = PurePosixPath(name).suffix.lower()
            if suffix in NATIVE_EXTENSIONS:
                native_files.append(name)
                seen_extensions.add(suffix)

        # Infer build deps from file extensions
        inferred = set()
        for ext in seen_extensions:
            dep = EXTENSION_TO_BUILD_DEP.get(ext)
            if dep:
                inferred.add(_normalize_name(dep))

        # Parse declared build deps and build-system metadata
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

        # Detect legacy setup.py-only packages (no pyproject.toml)
        has_setup_py = _find_config_file(members, "setup.py") is not None
    finally:
        close_fn()

    # Deduplicate declared
    seen = set()
    declared_dedup = []
    for name in declared:
        if name not in seen:
            seen.add(name)
            declared_dedup.append(name)

    # Compute extra_deps: names from declared + inferred that are resolvable
    # from available_deps but not already in the explicit deps list.
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
