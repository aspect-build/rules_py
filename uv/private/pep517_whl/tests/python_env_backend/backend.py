from __future__ import annotations

import base64
import csv
import hashlib
import io
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


_DIST_INFO = "python_env_backend-0.0.1.dist-info"


def _check_environment() -> None:
    # JAVA_RUNFILES is Bazel's legacy runfiles locator, not a Java toolchain
    # variable. Compiler and Java tool variables remain available to backends;
    # only the parent launcher's runfiles identity must be removed.
    for name in (
        "JAVA_RUNFILES",
        "PYTHONHOME",
        "PYTHONPLATLIBDIR",
        "RUNFILES_DIR",
        "RUNFILES_MANIFEST_FILE",
        "RUNFILES_MANIFEST_ONLY",
    ):
        if name in os.environ:
            raise RuntimeError(f"inherited {name} reached the PEP 517 backend")

    expected_pythonpath = os.environ.get("EXPECTED_PYTHONPATH")
    if expected_pythonpath is None:
        if "PYTHONPATH" in os.environ:
            raise RuntimeError("host PYTHONPATH reached the PEP 517 backend")
    elif os.environ.get("PYTHONPATH") != expected_pythonpath:
        raise RuntimeError("explicit PYTHONPATH did not reach the PEP 517 backend")

    if os.environ.get("PYTHONSAFEPATH") != "1":
        raise RuntimeError("unrelated PYTHONSAFEPATH was not preserved")


def get_requires_for_build_wheel(
    config_settings: dict[str, object] | None = None,
) -> list[str]:
    del config_settings
    _check_environment()
    return []


def build_wheel(
    wheel_directory: str,
    config_settings: dict[str, object] | None = None,
    metadata_directory: str | None = None,
) -> str:
    del config_settings, metadata_directory
    _check_environment()

    files = {
        f"{_DIST_INFO}/METADATA": (
            "Metadata-Version: 2.1\n"
            "Name: python-env-backend\n"
            "Version: 0.0.1\n"
        ).encode(),
        f"{_DIST_INFO}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: rules_py test backend\n"
            "Root-Is-Purelib: true\n"
            "Tag: py3-none-any\n"
        ).encode(),
    }
    record_rows: list[list[str]] = []
    for name, content in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).rstrip(b"=")
        record_rows.append([name, "sha256=" + digest.decode(), str(len(content))])
    record_rows.append([f"{_DIST_INFO}/RECORD", "", ""])

    record = io.StringIO()
    writer = csv.writer(record, lineterminator="\n")
    writer.writerows(record_rows)
    files[f"{_DIST_INFO}/RECORD"] = record.getvalue().encode()

    wheel_name = "python_env_backend-0.0.1-py3-none-any.whl"
    wheel_path = Path(wheel_directory, wheel_name)
    with ZipFile(wheel_path, "w", ZIP_DEFLATED) as wheel:
        for name, content in files.items():
            wheel.writestr(name, content)
    return wheel_name
