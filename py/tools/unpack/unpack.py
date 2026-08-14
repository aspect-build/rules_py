"""Wheel installer for aspect_rules_py WhlInstall and PyUnpackedWheel actions.

Installs a single wheel into::

    <into>/lib/python<M>.<m>/site-packages/

following PEP 427 ``.data/`` routing for scripts, headers, and data files.
Optionally applies patch files and pre-compiles ``.pyc`` bytecode.

Invoked by Bazel as::

    <exec_python> unpack.py --into <dir> --wheel <file> --python-version M.m [...]
"""

from __future__ import annotations

# Module-level imports are the bulk of this tool's per-action startup cost;
# anything conditional (subprocess, configparser, urllib.parse, exclude_glob)
# is imported where it's needed instead.
import csv
import hashlib
import io
import os
import re
import shutil
import sys
import zipfile
from base64 import urlsafe_b64encode
from collections.abc import Sequence
from pathlib import Path

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


def _import_root(path: Path) -> str | None:
    parts = path.parts
    if not parts:
        return None
    root = parts[0]
    if (
        not root.endswith((".dist-info", ".egg-info"))
        and (
            len(parts) > 1
            or path.name.endswith((".py", ".pyi"))
            or (path.name.endswith(".pyc") and path.parent.name != "__pycache__")
            or _is_native_library(path)
        )
    ):
        return root
    return None


# Prefix roots whose on-disk contents cannot be attributed to a PEP 427
# category: `bin/` holds `.data/scripts/` and generated console scripts, `lib/`
# holds site-packages and `.data/headers/`, either alongside a `.data/data/`
# file routed there. Both sides of the data-file comparison drop them — venv
# assembly never projects a data file into them either (`VENV_OWNED_ROOTS` in
# virtuals_resolvers.bzl), so a patch touching one is inconsequential.
_AMBIGUOUS_PREFIX_ROOTS = ("bin", "lib")


def _prefix_data_files(into: Path) -> set[str]:
    """Prefix-relative paths of the installed `.data/data/` tree.

    Descends only the roots that hold data files, so the walk is bounded by the
    prefix tree rather than by site-packages, which for a large wheel is orders
    of magnitude bigger and entirely excluded anyway.
    """
    found: set[str] = set()
    for entry in into.iterdir():
        if entry.name in _AMBIGUOUS_PREFIX_ROOTS:
            continue
        if entry.is_file():
            found.add(entry.name)
            continue
        for path in entry.rglob("*"):
            if path.is_file():
                found.add(path.relative_to(into).as_posix())
    return found


def _import_roots(site_packages: Path) -> set[str]:
    return {
        root
        for path in site_packages.rglob("*")
        if path.is_file()
        for root in [_import_root(path.relative_to(site_packages))]
        if root
    }


def cache_source_path(path: Path) -> Path | None:
    """Return the source a `.pyc` is reached through, or None if unreachable.

    Cache tags are stripped right to left, so a dotted source such as
    `mod.v1.py` resolves from `mod.v1.cpython-311.pyc`. Keep in sync with
    cache_source_path in uv/private/whl_install/metadata.bzl and the shared
    test vectors.
    """
    if not path.name.endswith(".pyc"):
        return None
    if path.parent.name != "__pycache__":
        return path.with_name(path.name[:-len(".pyc")] + ".py")
    source, separator, tag = path.name[:-len(".pyc")].rpartition(".")
    if tag.startswith("opt-"):
        if not tag[len("opt-"):]:
            return None
        source, separator, tag = source.rpartition(".")
    if not source or not separator or not tag:
        return None
    return path.parent.parent / (source + ".py")


def _path_excluded(
    path: Path, patterns: Sequence[tuple[str, ...]], is_file: bool
) -> bool:
    from exclude_glob import excluded

    if excluded(path.parts, patterns):
        return True
    if not is_file:
        return False
    source_path = cache_source_path(path)
    return source_path is not None and excluded(source_path.parts, patterns)


def _native_descendants(
    directory: Path, site_packages: Path, patterns: Sequence[tuple[str, ...]]
) -> tuple[str, ...]:
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
    directory: Path, site_packages: Path, patterns: Sequence[tuple[str, ...]]
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
    site_packages: Path, patterns: Sequence[tuple[str, ...]]
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
) -> tuple[str | None, dict[str, tuple[str, str]]]:
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


def _data_prefix(basename: str, record_dir: str | None) -> str:
    """Return the wheel's PEP 427 ``.data/`` prefix.

    ``.data`` and ``.dist-info`` share a stem, and RECORD spells its ``.data``
    paths with the stem the archive shipped -- which a build backend may escape
    differently from the filename (#1394). Prefer the stem carried by the
    archive; the filename is the fallback for a wheel with no usable RECORD.
    """
    if record_dir and record_dir.endswith(".dist-info") and "/" not in record_dir:
        return record_dir[: -len(".dist-info")] + ".data/"
    from urllib.parse import unquote

    return "-".join(unquote(basename).split("-")[:2]) + ".data/"


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
    python_version: str,
    into: Path,
    wheel_path: Path,
    exclude_patterns: Sequence[tuple[str, ...]],
    drop_pycache: bool = False,
) -> set[str]:
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

    site_packages = into / "lib" / ("python" + python_version) / "site-packages"
    bin_dir = into / "bin"
    site_packages.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    installed: dict[Path, tuple[str, str] | None] = {}
    seen_members: set[str] = set()
    original_import_roots: set[str] = set()

    with zipfile.ZipFile(wheel_path, "r") as zf:
        record_dir, record_metadata = _record_metadata(zf)
        data_prefix = _data_prefix(wheel_path.name, record_dir)
        regenerated_markers = ()
        if record_dir:
            regenerated_markers = (
                f"{record_dir}/INSTALLER",
                f"{record_dir}/REQUESTED",
            )
        for info in zf.infolist():
            member = info.filename
            if member.endswith("/"):
                continue
            member_path = _relative_path(member, "wheel member path")

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
                if (
                    drop_pycache
                    and dest.suffix == ".pyc"
                    and dest.parent.name == "__pycache__"
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
        import configparser

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

    return original_import_roots


class _Args:
    into: Path
    wheel: Path
    python_version: str

    def __init__(self) -> None:
        self.patches: list[Path] = []
        self.patch_strip = 0
        self.patch_tool = Path("patch")
        self.preserve_path: list[str] = []
        self.expected_data_files_manifest: Path | None = None
        self.exclude_glob: list[tuple[str, ...]] = []
        # Interpreter that compiles the bytecode; presence enables compilation.
        self.compile_pyc: Path | None = None
        self.pyc_invalidation_mode = "unchecked-hash"


def _parse_args(argv: Sequence[str]) -> _Args:
    """Parse the Bazel-generated argv by hand; argparse's import chain would
    dominate this tool's startup time."""
    args = _Args()
    flags = iter(argv)
    for flag in flags:
        flag, equals, value = flag.partition("=")
        if not equals:
            value = next(flags, None)
            if value is None:
                raise SystemExit("Missing value for flag: {}".format(flag))
        if flag == "--into":
            args.into = Path(value)
        elif flag == "--wheel":
            args.wheel = Path(value)
        elif flag == "--python-version":
            args.python_version = value
        elif flag == "--patch":
            args.patches.append(Path(value))
        elif flag == "--patch-strip":
            args.patch_strip = int(value)
        elif flag == "--patch-tool":
            args.patch_tool = Path(value)
        elif flag == "--preserve-path":
            args.preserve_path.append(value)
        elif flag == "--expected-data-files-manifest":
            # Newline-separated prefix-relative `.data/data/` paths; presence
            # enables the post-patch data-file check (an empty manifest is a
            # meaningful expectation). A file rather than repeated flags: a
            # wheel like jupyterlab ships thousands of prefix paths, enough to
            # risk ARG_MAX.
            args.expected_data_files_manifest = Path(value)
        elif flag == "--exclude-glob":
            from exclude_glob import parse

            args.exclude_glob.append(parse(value))
        elif flag == "--compile-pyc":
            args.compile_pyc = Path(value)
        elif flag == "--pyc-invalidation-mode":
            args.pyc_invalidation_mode = value
        else:
            raise SystemExit("Unknown flag: {}".format(flag))
    for required in ("into", "wheel", "python_version"):
        if not hasattr(args, required):
            raise SystemExit(
                "Missing required flag: --{}".format(required.replace("_", "-"))
            )
    return args


def main() -> None:
    args = _parse_args(sys.argv[1:])

    original_import_roots = install_wheel(
        args.python_version,
        args.into,
        args.wheel,
        args.exclude_glob if not args.patches else (),
        # Supplied bytecode outlives the source it was built from.
        bool(args.compile_pyc or args.patches),
    )

    site_packages = (
        args.into / "lib" / ("python" + args.python_version) / "site-packages"
    )
    # Analysis uses these paths for collision and merge planning. Snapshot their
    # installed shape here, where both the before and after states are available.
    observed_files: list[Path] = []
    observed_directories: dict[Path, tuple[bool | None, tuple[str, ...]]] = {}
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
        import subprocess

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

    # Venv assembly projects the `.data/data/` prefix files (share/, etc/) from
    # metadata settled during analysis. Unlike the site-packages topology they
    # are not covered by the preserve-path checks above, so a patch that alters
    # the set cannot be reflected: an added file would be missing from
    # sys.prefix, a removed/renamed one would dangle. A forwarded manifest means
    # the resulting prefix tree must match it exactly. Content edits are fine —
    # the symlink resolves through — only the path set is guarded.
    if args.expected_data_files_manifest:
        expected = {
            path
            for path in args.expected_data_files_manifest.read_text(
                encoding="utf-8",
            ).splitlines()
            if path and path.split("/")[0] not in _AMBIGUOUS_PREFIX_ROOTS
        }
        actual = _prefix_data_files(args.into)
        removed = sorted(expected - actual)
        added = sorted(actual - expected)
        if removed or added:
            raise SystemExit(
                "Post-install patch altered the wheel's `.data/data/` prefix files "
                "(removed={}, added={}). Venv assembly projects the set settled "
                "during analysis, so an added file is missing from sys.prefix and a "
                "removed or renamed one leaves a dangling symlink. Keep the patch "
                "out of the prefix tree; editing an existing data file's contents "
                "is supported.".format(removed, added)
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
        record_paths = set(records)
        rows = []
        for path in sorted(args.into.rglob("*")):
            if not path.is_file() or path in record_paths:
                continue
            # A patch can invalidate pre-compiled pyc
            if (
                args.patches
                and path.suffix == ".pyc"
                and path.parent.name == "__pycache__"
                and site_packages in path.parents
            ):
                path.unlink()
                continue
            relative = os.path.relpath(str(path), str(site_packages)).replace("\\", "/")
            rows.append((relative, _sha256(path), str(path.stat().st_size)))
        for record in records:
            with record.open("w", newline="", encoding="utf-8") as stream:
                csv.writer(stream).writerows([
                    *rows,
                    (record.relative_to(site_packages).as_posix(), "", ""),
                ])

    if args.compile_pyc:
        import subprocess

        # Wheels may retain source for older Python versions. Match pip by
        # retaining compileall's diagnostics while ignoring its aggregate
        # false result; check=True still rejects abnormal interpreter exits.
        # https://github.com/pypa/pip/blob/c8651d86d2d080c1936974873ab162f9c2507666/src/pip/_internal/operations/install/wheel.py#L623-L639
        subprocess.run(
            [
                str(args.compile_pyc),
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

        # Unlike pip, compiled bytecode stays out of RECORD: nothing uninstalls
        # from an immutable tree, so the rows are not worth a hash of each file.


if __name__ == "__main__":
    main()
