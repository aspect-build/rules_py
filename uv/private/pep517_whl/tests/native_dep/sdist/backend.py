"""Build a native extension whose compile/link inputs live outside the sdist."""

from __future__ import annotations

import base64
import csv
import hashlib
import io
import os
import shlex
import subprocess
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

_DIST_INFO = "native_dep_ext-0.0.1.dist-info"
_EXT = "native_dep_ext.so"


def _compile() -> None:
    for key in ("AR", "LD", "STRIP"):
        value = os.environ[key]
        expected = os.environ.get(f"EXPECTED_{key}")
        if expected is not None:
            if value != expected:
                raise RuntimeError(f"{key} must remain {expected!r}, got {value!r}")
        elif not Path(value).is_absolute() or not Path(value).exists():
            raise RuntimeError(f"{key} must be an absolute toolchain path, got {value!r}")

    cc = shlex.split(os.environ["CC"])
    cppflags = shlex.split(os.environ["CPPFLAGS"])
    ldflags = shlex.split(os.environ["LDFLAGS"])
    subprocess.run([*cc, "-fPIC", *cppflags, "-c", "mod.c", "-o", "mod.o"], check=True)
    ar = shlex.split(os.environ["AR"])
    archive_args = ["-static", "-o", "mod.a", "mod.o"] if "libtool" in Path(ar[0]).name else ["rcs", "mod.a", "mod.o"]
    subprocess.run([*ar, *archive_args], check=True)
    subprocess.run([*cc, "-shared", "mod.o", *ldflags, "-o", _EXT], check=True)


def get_requires_for_build_wheel(config_settings=None):
    del config_settings
    return []


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    del config_settings, metadata_directory
    _compile()

    files = {
        _EXT: Path(_EXT).read_bytes(),
        f"{_DIST_INFO}/METADATA": (
            "Metadata-Version: 2.1\nName: native-dep-ext\nVersion: 0.0.1\n"
        ).encode(),
        f"{_DIST_INFO}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: rules_py native-dep test backend\n"
            "Root-Is-Purelib: false\n"
            "Tag: py3-none-linux_x86_64\n"
        ).encode(),
    }

    rows = []
    for name, content in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).rstrip(b"=")
        rows.append([name, "sha256=" + digest.decode(), str(len(content))])
    rows.append([f"{_DIST_INFO}/RECORD", "", ""])
    record = io.StringIO()
    csv.writer(record, lineterminator="\n").writerows(rows)
    files[f"{_DIST_INFO}/RECORD"] = record.getvalue().encode()

    wheel_name = "native_dep_ext-0.0.1-py3-none-linux_x86_64.whl"
    with ZipFile(Path(wheel_directory, wheel_name), "w", ZIP_DEFLATED) as wheel:
        for name, content in files.items():
            wheel.writestr(name, content)
    return wheel_name
