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
import os
import subprocess
import zipfile
from base64 import urlsafe_b64encode
from pathlib import Path
from urllib.parse import unquote

_RELOCATABLE_SHEBANG = """\
#!/bin/sh
'''exec' "$(dirname -- "$(realpath -- "$0")")"/'python3' "$0" "$@"
' '''
"""


def _sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256=" + urlsafe_b64encode(h.digest()).decode().rstrip("=")


def _has_python_shebang(data):
    return data.startswith(b"#!") and b"python" in data.split(b"\n", 1)[0]


def _write_executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o755)


def install_wheel(version_major, version_minor, into, wheel_path):
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

    installed = []

    with zipfile.ZipFile(wheel_path, "r") as zf:
        for info in zf.infolist():
            member = info.filename
            if member.endswith("/"):
                continue

            is_script = False
            if member.startswith(data_prefix):
                rest = member[len(data_prefix):]
                category, sep, rel = rest.partition("/")
                if not sep:
                    continue
                if category in ("purelib", "platlib"):
                    dest = site_packages / rel
                elif category == "scripts":
                    dest = bin_dir / Path(rel).name
                    is_script = True
                elif category == "headers":
                    dest = into / "lib" / "include" / rel
                elif category == "data":
                    dest = into / rel
                else:
                    dest = site_packages / rest
            else:
                dest = site_packages / member

            dest.parent.mkdir(parents=True, exist_ok=True)
            data = zf.read(member)

            if is_script and _has_python_shebang(data):
                _, _, body = data.partition(b"\n")
                data = _RELOCATABLE_SHEBANG.encode() + body

            dest.write_bytes(data)

            unix_mode = (info.external_attr >> 16) & 0xFFFF
            if unix_mode & 0o111 or is_script:
                dest.chmod(dest.stat().st_mode | 0o111)

            if not member.endswith("/RECORD"):
                installed.append(dest)

    for ep_path in site_packages.glob("*.dist-info/entry_points.txt"):
        cp = configparser.ConfigParser(strict=False)
        cp.optionxform = str
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
                script_path = bin_dir / name
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
                installed.append(script_path)

    for record_path in site_packages.glob("*.dist-info/RECORD"):
        dist_info = record_path.parent

        installer_path = dist_info / "INSTALLER"
        installer_path.write_text("aspect_rules_py", encoding="utf-8")

        requested_path = dist_info / "REQUESTED"
        requested_path.write_bytes(b"")

        rows = []
        for f in installed:
            rel = os.path.relpath(str(f), str(site_packages)).replace("\\", "/")
            rows.append((rel, _sha256(f), str(f.stat().st_size)))
        for meta_file in (installer_path, requested_path):
            rel = os.path.relpath(str(meta_file), str(site_packages)).replace("\\", "/")
            rows.append((rel, _sha256(meta_file), str(meta_file.stat().st_size)))
        rel_record = os.path.relpath(str(record_path), str(site_packages)).replace("\\", "/")
        rows.append((rel_record, "", ""))
        with record_path.open("w", newline="", encoding="utf-8") as fh:
            csv.writer(fh).writerows(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--into", required=True, type=Path)
    ap.add_argument("--wheel", required=True, type=Path)
    ap.add_argument("--python-version-major", required=True, type=int)
    ap.add_argument("--python-version-minor", required=True, type=int)
    ap.add_argument("--patch", dest="patches", action="append", default=[], type=Path)
    ap.add_argument("--patch-strip", type=int, default=0)
    ap.add_argument("--patch-tool", type=Path, default=Path("patch"))
    ap.add_argument("--preserve-path", action="append", default=[])
    ap.add_argument("--compile-pyc", action="store_true")
    ap.add_argument("--pyc-invalidation-mode", default="checked-hash",
                    choices=["checked-hash", "unchecked-hash", "timestamp"])
    ap.add_argument("--python", type=Path)
    args = ap.parse_args()

    install_wheel(
        args.python_version_major,
        args.python_version_minor,
        args.into,
        args.wheel,
    )

    site_packages = (
        args.into / "lib"
        / "python{}.{}".format(args.python_version_major, args.python_version_minor)
        / "site-packages"
    )
    # Analysis uses these paths for collision and merge planning. Snapshot their
    # installed shape here, where both the before and after states are available.
    observed_files = []
    observed_directory_init = {}
    for relative_string in args.preserve_path:
        relative = Path(relative_string)
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit("Invalid preserved wheel path: {}".format(relative))
        path = site_packages / relative
        if path.is_dir():
            observed_directory_init[relative] = (path / "__init__.py").is_file()
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
    for relative, had_init in observed_directory_init.items():
        directory = site_packages / relative
        if not directory.is_dir():
            raise SystemExit(
                "Post-install patch changed observed wheel directory: {}".format(relative)
            )
        if (directory / "__init__.py").is_file() != had_init:
            raise SystemExit(
                "Post-install patch changed observed package classification: {}".format(relative)
            )

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


if __name__ == "__main__":
    main()
