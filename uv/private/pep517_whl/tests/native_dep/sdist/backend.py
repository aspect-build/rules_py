"""PEP 517 backend for the regression test: compiles mod.c with the
env-supplied CC/CPPFLAGS/LDFLAGS, so the build succeeds only if those
workspace-relative flag paths resolve from this backend's worktree cwd."""

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
    cc = shlex.split(os.environ.get("CC") or "cc")
    cppflags = shlex.split(os.environ.get("CPPFLAGS", ""))
    ldflags = shlex.split(os.environ.get("LDFLAGS", ""))
    subprocess.run([*cc, "-fPIC", *cppflags, "-c", "mod.c", "-o", "mod.o"], check=True)
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

    rows: list[list[str]] = []
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
