"""Wheel installer for aspect_rules_py WhlInstall and PyUnpackedWheel actions.

Installs a single wheel into::

    <into>/lib/python<M>.<m>/site-packages/

following PEP 427 ``.data/`` routing for scripts, headers, and data files.
Optionally applies patch files and pre-compiles ``.pyc`` bytecode.

Invoked by Bazel as::

    <exec_python> unpack.py --into <dir> --wheel <file> --python-version-major N --python-version-minor M [...]
"""

import argparse
import configparser
import csv
import hashlib
import io
import os
import re
import shutil
import subprocess
import zipfile
from base64 import urlsafe_b64encode
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple
from urllib.parse import unquote

_RELOCATABLE_SHEBANG = """\
#!/bin/sh
'''exec' "$(dirname -- "$(realpath -- "$0")")"/'python3' "$0" "$@"
' '''
"""

_WINDOWS_RESERVED = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"} | {
    prefix + suffix for prefix in ("COM", "LPT") for suffix in "123456789¹²³"
}


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256=" + urlsafe_b64encode(h.digest()).decode().rstrip("=")


def _has_python_shebang(data: bytes) -> bool:
    return data.startswith(b"#!") and b"python" in data.split(b"\n", 1)[0]


def _is_native_library(path: Path) -> bool:
    name = path.name
    _, so_separator, so_version = name.partition(".so.")
    return (
        name.endswith((".so", ".pyd", ".dylib", ".dll"))
        or bool(so_separator and so_version and so_version[0].isdigit())
    )


def _import_root(path: Path) -> Optional[str]:
    if (
        path.parts
        and not path.parts[0].endswith((".dist-info", ".egg-info"))
        and (
            len(path.parts) > 1
            or path.name.endswith((".py", ".pyi"))
            or (path.name.endswith(".pyc") and path.parent.name != "__pycache__")
            or _is_native_library(path)
        )
    ):
        return path.parts[0]
    return None


def _import_roots(site_packages: Path) -> Set[str]:
    return {
        root
        for path in site_packages.rglob("*")
        if path.is_file()
        for root in [_import_root(path.relative_to(site_packages))]
        if root
    }


def _path_excluded(
    path: Path, patterns: Sequence[Tuple[str, ...]], is_file: bool
) -> bool:
    from exclude_glob import excluded

    # Keep cache-to-source matching in sync with record_path_excluded in
    # uv/private/whl_install/repository.bzl and the shared test vectors.
    if excluded(path.parts, patterns):
        return True
    if not is_file or not path.name.endswith(".pyc"):
        return False
    if path.parent.name == "__pycache__":
        source, separator, tag = path.stem.rpartition(".")
        if tag.startswith("opt-"):
            if not tag[len("opt-"):]:
                return False
            source, separator, tag = source.rpartition(".")
        if not source or not separator or not tag:
            return False
        source_path = path.parent.parent / (source + ".py")
    else:
        source_path = path.with_name(path.name[:-len(".pyc")] + ".py")
    return excluded(source_path.parts, patterns)


def _native_descendants(
    directory: Path, site_packages: Path, patterns: Sequence[Tuple[str, ...]]
) -> Tuple[str, ...]:
    return tuple(sorted(
        path.relative_to(directory).as_posix()
        for path in directory.rglob("*")
        if path.is_file()
        and _is_native_library(path)
        and (
            not patterns
            or not _path_excluded(path.relative_to(site_packages), patterns, True)
        )
    ))


def _retained_init(
    directory: Path, site_packages: Path, patterns: Sequence[Tuple[str, ...]]
) -> bool:
    init = directory / "__init__.py"
    if not init.is_file():
        return False
    if not patterns:
        return True
    return not _path_excluded(init.relative_to(site_packages), patterns, True)


def _installer_input(path: Path) -> bool:
    return (
        len(path.parts) == 2
        and path.parts[0].endswith(".dist-info")
        and path.name in ("entry_points.txt", "RECORD")
    )


def _remove_excluded(
    site_packages: Path, patterns: Sequence[Tuple[str, ...]]
) -> None:
    for path in sorted(site_packages.rglob("*"), reverse=True):
        if not _path_excluded(
            path.relative_to(site_packages),
            patterns,
            path.is_file(),
        ):
            continue
        if path.is_dir():
            path.rmdir()
        else:
            path.unlink()

    for cache in site_packages.rglob("__pycache__"):
        if cache.is_dir() and not any(cache.iterdir()):
            cache.rmdir()


def _write_executable(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o755)


def _record_metadata(
    zf: zipfile.ZipFile,
) -> Tuple[Optional[str], Dict[str, Tuple[str, str]]]:
    """Return reusable sha256/size metadata from one well-formed RECORD."""
    record_members = [
        info.filename
        for info in zf.infolist()
        if info.filename.endswith("/RECORD")
    ]
    if len(record_members) != 1:
        return None, {}

    record_member = record_members[0]
    record_dir = record_member.rsplit("/", 1)[0]
    rows = {}
    try:
        with zf.open(record_member) as raw:
            with io.TextIOWrapper(raw, encoding="utf-8", newline="") as text:
                for path, digest, size in csv.reader(text):
                    if path in rows:
                        return record_dir, {}
                    rows[path] = (digest, size)
    except (ValueError, csv.Error, UnicodeDecodeError):
        return record_dir, {}
    return record_dir, {
        path: values
        for path, values in rows.items()
        # The final unpadded base64 character carries only four digest bits.
        if re.fullmatch(r"sha256=[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]", values[0])
        and values[1].isdecimal()
    }


def _relative_path(value: str, what: str) -> Path:
    """Return a safe host path for a wheel-controlled POSIX path."""
    parts = value.split("/")
    if (
        not value
        or "\\" in value
        or any(
            not part
            or part.endswith((" ", "."))
            or ":" in part
            or part.partition(".")[0].rstrip(" ").upper() in _WINDOWS_RESERVED
            for part in parts
        )
    ):
        raise SystemExit("Invalid {}: {}".format(what, value))
    return Path(*parts)


def install_wheel(
    version_major: int,
    version_minor: int,
    into: Path,
    wheel_path: Path,
    exclude_patterns: Sequence[Tuple[str, ...]],
) -> Tuple[Dict[Path, Optional[Tuple[str, str]]], Set[str]]:
    """Install a wheel into *into*, following PEP 427 layout conventions.

    Accepts either a direct ``.whl`` file or a directory containing exactly
    one ``.whl`` (the shape produced by Bazel's ``http_file`` rule).
    """
    if wheel_path.is_dir():
        whls = list(wheel_path.glob("*.whl"))
        if len(whls) != 1:
            raise SystemExit(
                "Expected exactly one .whl in {}, found {}".format(wheel_path, len(whls))
            )
        wheel_path = whls[0]

    wheel_name = unquote(wheel_path.name)
    data_prefix = "-".join(wheel_name.split("-")[:2]) + ".data/"

    site_packages = into / "lib" / "python{}.{}".format(version_major, version_minor) / "site-packages"
    bin_dir = into / "bin"
    site_packages.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    installed: Dict[Path, Optional[Tuple[str, str]]] = {}
    seen_members: Set[str] = set()
    original_import_roots: Set[str] = set()

    with zipfile.ZipFile(wheel_path, "r") as zf:
        record_dir, record_metadata = _record_metadata(zf)
        regenerated_markers = ()
        if record_dir:
            regenerated_markers = (
                f"{record_dir}/INSTALLER",
                f"{record_dir}/REQUESTED",
            )
        for info in zf.infolist():
            member = info.filename
            member_path = _relative_path(
                member[:-1] if member.endswith("/") else member,
                "wheel member path",
            )
            if member.endswith("/"):
                continue

            is_script = False
            if member.startswith(data_prefix):
                rest = member[len(data_prefix):]
                category, sep, rel = rest.partition("/")
                if not sep:
                    continue
                rel_path = _relative_path(rel, "wheel member path")
                if category in ("purelib", "platlib"):
                    dest = site_packages / rel_path
                elif category == "scripts":
                    dest = bin_dir / rel_path.name
                    is_script = True
                elif category == "headers":
                    dest = into / "lib" / "include" / rel_path
                elif category == "data":
                    dest = into / rel_path
                else:
                    dest = site_packages / category / rel_path
            else:
                dest = site_packages / member_path

            try:
                site_relative = dest.relative_to(site_packages)
            except ValueError:
                pass
            else:
                root = _import_root(site_relative)
                if root:
                    original_import_roots.add(root)
                if (
                    exclude_patterns
                    and _path_excluded(site_relative, exclude_patterns, True)
                    and not _installer_input(site_relative)
                ):
                    continue

            dest.parent.mkdir(parents=True, exist_ok=True)
            reusable_record = record_metadata.get(member)
            if member in seen_members:
                reusable_record = None
            seen_members.add(member)
            if is_script:
                data = zf.read(member)
                if _has_python_shebang(data):
                    _, _, body = data.partition(b"\n")
                    data = _RELOCATABLE_SHEBANG.encode() + body
                    reusable_record = None
                dest.write_bytes(data)
            else:
                with zf.open(info, "r") as source, dest.open("wb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)

            unix_mode = (info.external_attr >> 16) & 0xFFFF
            if unix_mode & 0o111 or is_script:
                dest.chmod(dest.stat().st_mode | 0o111)

            if not member.endswith("/RECORD") and member not in regenerated_markers:
                if reusable_record is not None and reusable_record[1] != str(info.file_size):
                    reusable_record = None
                installed[dest] = reusable_record
    for ep_path in site_packages.glob("*.dist-info/entry_points.txt"):
        cp = configparser.ConfigParser(strict=False, delimiters=("=",))
        setattr(cp, "optionxform", str)
        cp.read(str(ep_path), encoding="utf-8")
        for section in ("console_scripts", "gui_scripts"):
            if section not in cp:
                continue
            for raw_name, raw_ep in cp[section].items():
                module, _, func_extras = raw_ep.strip().partition(":")
                func = func_extras.split("[")[0].strip()
                name = raw_name.strip()
                module = module.strip()
                if not name or not module or not func:
                    continue
                name_path = _relative_path(name, "console script name")
                if len(name_path.parts) != 1:
                    raise SystemExit("Invalid console script name: {}".format(name))
                script_path = bin_dir / name_path
                # Entry-point object references may contain dotted attributes:
                # https://packaging.python.org/en/latest/specifications/entry-points/#data-model
                wrapper = (
                    _RELOCATABLE_SHEBANG
                    + "# -*- coding: utf-8 -*-\n"
                    + "import sys\n"
                    + "from importlib import import_module\n"
                    + "from operator import attrgetter\n"
                    + "sys.exit(attrgetter({!r})(import_module({!r}))())\n".format(
                        func,
                        module,
                    )
                )
                _write_executable(script_path, wrapper.encode())
                installed[script_path] = None

    for record_path in site_packages.glob("*.dist-info/RECORD"):
        dist_info = record_path.parent

        installer_path = dist_info / "INSTALLER"
        installer_path.write_text("aspect_rules_py", encoding="utf-8")

        requested_path = dist_info / "REQUESTED"
        requested_path.write_bytes(b"")

        rows = []
        for f, reusable_record in installed.items():
            rel = os.path.relpath(str(f), str(site_packages)).replace("\\", "/")
            if reusable_record is not None:
                rows.append((rel, reusable_record[0], reusable_record[1]))
            else:
                rows.append((rel, _sha256(f), str(f.stat().st_size)))
        for meta_file in (installer_path, requested_path):
            rel = os.path.relpath(str(meta_file), str(site_packages)).replace("\\", "/")
            rows.append((rel, _sha256(meta_file), str(meta_file.stat().st_size)))
        rel_record = os.path.relpath(str(record_path), str(site_packages)).replace("\\", "/")
        rows.append((rel_record, "", ""))
        with record_path.open("w", newline="", encoding="utf-8") as fh:
            csv.writer(fh).writerows(rows)

    return installed, original_import_roots


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--into", required=True, type=Path)
    ap.add_argument("--wheel", required=True, type=Path)
    ap.add_argument("--python-version-major", required=True, type=int)
    ap.add_argument("--python-version-minor", required=True, type=int)
    ap.add_argument("--patch", dest="patches", action="append", default=[], type=Path)
    ap.add_argument("--patch-strip", type=int, default=0)
    ap.add_argument("--patch-tool", type=Path, default=Path("patch"))
    ap.add_argument("--preserve-path", action="append", default=[])
    ap.add_argument("--exclude-glob", action="append", default=[])
    ap.add_argument("--compile-pyc", action="store_true")
    ap.add_argument("--pyc-invalidation-mode", default="checked-hash",
                    choices=["checked-hash", "unchecked-hash", "timestamp"])
    ap.add_argument("--python", type=Path)
    args = ap.parse_args()
    if args.exclude_glob:
        from exclude_glob import parse

        args.exclude_glob = [parse(pattern) for pattern in args.exclude_glob]

    installed, original_import_roots = install_wheel(
        args.python_version_major,
        args.python_version_minor,
        args.into,
        args.wheel,
        args.exclude_glob if not args.patches else (),
    )

    site_packages = (
        args.into / "lib"
        / "python{}.{}".format(args.python_version_major, args.python_version_minor)
        / "site-packages"
    )
    supplied_pyc = {
        path for path in installed
        if path.suffix == ".pyc" and site_packages in path.parents
    }
    # Analysis uses these paths for collision and merge planning. Snapshot their
    # installed shape here, where both the before and after states are available.
    observed_files: List[Path] = []
    observed_directories: Dict[Path, Tuple[Optional[bool], Tuple[str, ...]]] = {}
    for relative_string in args.preserve_path:
        relative = Path(relative_string)
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit("Invalid preserved wheel path: {}".format(relative))
        path = site_packages / relative
        if path.is_dir():
            observed_directories[relative] = (
                (
                    None
                    if relative.name.endswith((".dist-info", ".egg-info"))
                    else _retained_init(path, site_packages, args.exclude_glob)
                ),
                _native_descendants(path, site_packages, args.exclude_glob),
            )
        elif path.is_file():
            observed_files.append(relative)
        else:
            raise SystemExit("Preserved wheel path does not exist: {}".format(relative))

    for patch_file in args.patches:
        # --no-backup-if-mismatch: a fuzz/offset apply otherwise drops a
        # `<file>.orig` into the install tree, leaking into every consuming venv.
        with patch_file.open("rb") as patch_stream:
            r = subprocess.run(
                [
                    str(args.patch_tool),
                    "--no-backup-if-mismatch",
                    "-p{}".format(args.patch_strip),
                    "-d",
                    str(args.into),
                ],
                stdin=patch_stream,
            )
        # patch's rejected-hunk details go to the inherited stderr; fail the
        # action rather than emit a half-patched wheel.
        if r.returncode != 0:
            raise SystemExit(
                "Error: failed to apply patch {} (patch exited {}).".format(patch_file, r.returncode)
            )

    for relative in observed_files:
        if not (site_packages / relative).is_file():
            raise SystemExit(
                "Post-install patch changed observed wheel file: {}".format(relative)
            )
    for relative, (had_init, native_descendants) in observed_directories.items():
        directory = site_packages / relative
        if not directory.is_dir():
            raise SystemExit(
                "Post-install patch changed observed wheel directory: {}".format(relative)
            )
        if had_init is not None and _retained_init(directory, site_packages, args.exclude_glob) != had_init:
            raise SystemExit(
                "Post-install patch changed observed package classification: {}".format(relative)
            )
        if _native_descendants(directory, site_packages, args.exclude_glob) != native_descendants:
            raise SystemExit(
                "Post-install patch changed observed native files: {}".format(relative)
            )

    if args.exclude_glob:
        _remove_excluded(site_packages, args.exclude_glob)

        removed_roots = original_import_roots - _import_roots(site_packages)
        if removed_roots:
            raise SystemExit(
                "wheel exclusions removed top-level import roots: {}".format(
                    ", ".join(sorted(removed_roots))
                )
            )

    records = list(site_packages.glob("*.dist-info/RECORD"))
    if args.exclude_glob and len(records) != 1:
        raise SystemExit("expected exactly one installed RECORD, found {}".format(len(records)))
    if args.exclude_glob and not (records[0].parent / "METADATA").is_file():
        raise SystemExit("wheel exclusions removed installed METADATA")
    if records and (args.patches or args.exclude_glob):
        if args.patches:
            supplied_pyc = set()
        record_paths = set(records)
        rows = []
        for path in sorted(args.into.rglob("*")):
            if not path.is_file() or path in record_paths:
                continue
            if path.suffix == ".pyc" and site_packages in path.parents:
                supplied_pyc.add(path)
            relative = os.path.relpath(str(path), str(site_packages)).replace("\\", "/")
            rows.append((relative, _sha256(path), str(path.stat().st_size)))
        for record in records:
            with record.open("w", newline="", encoding="utf-8") as stream:
                csv.writer(stream).writerows([
                    *rows,
                    (record.relative_to(site_packages).as_posix(), "", ""),
                ])

    if args.compile_pyc:
        if not args.python:
            raise SystemExit("--python is required when --compile-pyc is set")
        # Wheels may retain source for older Python versions. Match pip by
        # retaining compileall's diagnostics while ignoring its aggregate
        # false result; check=True still rejects abnormal interpreter exits.
        # https://github.com/pypa/pip/blob/c8651d86d2d080c1936974873ab162f9c2507666/src/pip/_internal/operations/install/wheel.py#L623-L639
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
        if args.exclude_glob:
            _remove_excluded(site_packages, args.exclude_glob)

        if supplied_pyc:
            # compileall can replace bytecode that was already listed in RECORD.
            for record_path in site_packages.glob("*.dist-info/RECORD"):
                rows = []
                with record_path.open(newline="", encoding="utf-8") as record:
                    for relative, digest, size in csv.reader(record):
                        path = site_packages / relative
                        if path in supplied_pyc:
                            digest, size = _sha256(path), str(path.stat().st_size)
                        rows.append((relative, digest, size))
                with record_path.open("w", newline="", encoding="utf-8") as record:
                    csv.writer(record).writerows(rows)


if __name__ == "__main__":
    main()
