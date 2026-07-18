"""Copy an installed wheel tree, excluding site-packages-relative globs."""

import argparse
import csv
import hashlib
import importlib.util
import os
import shutil
import subprocess
from base64 import urlsafe_b64encode
from pathlib import Path

from exclude_glob import excluded, parse


def _is_import_file(path):
    name = path.name
    _, so_separator, so_version = name.partition(".so.")
    return (
        name.endswith((".py", ".so", ".pyd", ".dylib"))
        or (so_separator and so_version and so_version[0].isdigit())
    )


def _import_roots(site_packages):
    return {
        path.relative_to(site_packages).parts[0]
        for path in site_packages.rglob("*")
        if path.is_file()
        and _is_import_file(path)
        and not path.relative_to(site_packages).parts[0].endswith((".dist-info", ".egg-info"))
    }


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return "sha256=" + urlsafe_b64encode(digest.digest()).decode().rstrip("=")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="source", required=True, type=Path)
    parser.add_argument("--into", required=True, type=Path)
    parser.add_argument("--python-version-major", required=True, type=int)
    parser.add_argument("--python-version-minor", required=True, type=int)
    parser.add_argument("--exclude-glob", action="append", default=[], type=parse)
    parser.add_argument("--compile-pyc", action="store_true")
    parser.add_argument(
        "--pyc-invalidation-mode",
        default="checked-hash",
        choices=["checked-hash", "unchecked-hash", "timestamp"],
    )
    parser.add_argument("--python", type=Path)
    args = parser.parse_args()

    site_packages_relative = (
        Path("lib")
        / "python{}.{}".format(args.python_version_major, args.python_version_minor)
        / "site-packages"
    )
    source_site_packages = args.source / site_packages_relative

    def ignored(directory, names):
        try:
            parent = Path(directory).relative_to(source_site_packages)
        except ValueError:
            return []
        return [
            name
            for name in names
            if excluded((parent / name).parts, args.exclude_glob)
        ]

    shutil.copytree(args.source, args.into, symlinks=False, ignore=ignored, dirs_exist_ok=True)
    site_packages = args.into / site_packages_relative

    # File-shaped source globs do not match their PEP 3147 or legacy caches.
    # Remove only bytecode whose corresponding source path was excluded.
    for bytecode in site_packages.rglob("*.pyc"):
        if bytecode.parent.name == "__pycache__":
            try:
                source_path = Path(importlib.util.source_from_cache(str(bytecode)))
            except ValueError:
                continue
        else:
            source_path = bytecode.with_suffix(".py")
        if excluded(source_path.relative_to(site_packages).parts, args.exclude_glob):
            bytecode.unlink()
    for cache in site_packages.rglob("__pycache__"):
        if cache.is_dir() and not any(cache.iterdir()):
            cache.rmdir()

    removed_roots = _import_roots(source_site_packages) - _import_roots(site_packages)
    if removed_roots:
        raise SystemExit(
            "wheel exclusions removed top-level import roots: {}".format(
                ", ".join(sorted(removed_roots))
            )
        )

    records = list(site_packages.glob("*.dist-info/RECORD"))
    if len(records) != 1:
        raise SystemExit("expected exactly one installed RECORD, found {}".format(len(records)))
    record = records[0]
    rows = []
    for path in sorted(args.into.rglob("*")):
        if not path.is_file() or path == record:
            continue
        relative = os.path.relpath(path, site_packages).replace("\\", "/")
        rows.append((relative, _sha256(path), str(path.stat().st_size)))
    rows.append((record.relative_to(site_packages).as_posix(), "", ""))
    record.unlink()
    with record.open("w", newline="", encoding="utf-8") as stream:
        csv.writer(stream).writerows(rows)

    if args.compile_pyc:
        if not args.python:
            raise SystemExit("--python is required when --compile-pyc is set")
        subprocess.run(
            [
                str(args.python),
                "-c",
                "import compileall; compileall.main()",
                "-q",
                "--invalidation-mode",
                args.pyc_invalidation_mode,
                "--",
                str(site_packages),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
