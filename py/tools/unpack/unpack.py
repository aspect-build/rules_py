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
import json
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


def _entry_point_scripts(site_packages, sections):
    scripts = {}
    for ep_path in site_packages.glob("*.dist-info/entry_points.txt"):
        cp = configparser.ConfigParser(strict=False)
        cp.optionxform = str
        cp.read(str(ep_path), encoding="utf-8")
        for section in sections:
            if section not in cp:
                continue
            for raw_name, raw_ep in cp[section].items():
                module, _, func_extras = raw_ep.strip().partition(":")
                func = func_extras.split("[")[0].strip()
                name = raw_name.strip()
                if name and module.strip() and func:
                    scripts[name] = "{}={}:{}".format(name, module.strip(), func)
    return scripts


def _validate_metadata(site_packages, expected):
    actual = {
        "console_scripts": sorted(
            _entry_point_scripts(site_packages, ("console_scripts",)).values()
        ),
        "top_levels": {
            entry.name: "directory" if entry.is_dir() else "file"
            for entry in site_packages.iterdir()
        },
    }
    if actual != expected:
        raise SystemExit(
            "Installed wheel metadata changed after repository analysis:\n"
            "expected {}\nactual {}".format(
                json.dumps(expected, sort_keys=True),
                json.dumps(actual, sort_keys=True),
            )
        )


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

    for encoded in _entry_point_scripts(
        site_packages,
        ("console_scripts", "gui_scripts"),
    ).values():
        name, _, target = encoded.partition("=")
        module, _, func = target.partition(":")
        script_path = bin_dir / name
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
    os.umask(0o022)

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--into", required=True, type=Path)
    ap.add_argument("--wheel", required=True, type=Path)
    ap.add_argument("--python-version-major", required=True, type=int)
    ap.add_argument("--python-version-minor", required=True, type=int)
    ap.add_argument("--patch", dest="patches", action="append", default=[], type=Path)
    ap.add_argument("--patch-strip", type=int, default=0)
    ap.add_argument("--patch-tool", type=Path, default=Path("patch"))
    ap.add_argument("--compile-pyc", action="store_true")
    ap.add_argument("--pyc-invalidation-mode", default="checked-hash",
                    choices=["checked-hash", "unchecked-hash", "timestamp"])
    ap.add_argument("--python", type=Path)
    ap.add_argument("--expected-metadata", type=json.loads)
    ap.add_argument("--metadata-unavailable", action="store_true")
    args = ap.parse_args()

    install_wheel(
        args.python_version_major,
        args.python_version_minor,
        args.into,
        args.wheel,
    )

    for patch_file in args.patches:
        r = subprocess.run(
            [str(args.patch_tool), "-p{}".format(args.patch_strip), "-d", str(args.into)],
            stdin=patch_file.open("rb"),
        )
        if r.returncode != 0:
            raise SystemExit("patch failed ({}) for {}".format(r.returncode, patch_file))

    site_packages = (
        args.into / "lib"
        / "python{}.{}".format(args.python_version_major, args.python_version_minor)
        / "site-packages"
    )
    if args.metadata_unavailable and _entry_point_scripts(
        site_packages,
        ("console_scripts",),
    ):
        raise SystemExit(
            "Source-built wheels with console scripts are unsupported because "
            "their names are unavailable during Bazel analysis."
        )

    if args.compile_pyc:
        if not args.python:
            raise SystemExit("--python is required when --compile-pyc is set")
        subprocess.run(
            [
                str(args.python), "-m", "compileall", "-q",
                "--invalidation-mode", args.pyc_invalidation_mode,
                str(site_packages),
            ]
        )

    if args.expected_metadata is not None:
        _validate_metadata(site_packages, args.expected_metadata)


if __name__ == "__main__":
    main()
