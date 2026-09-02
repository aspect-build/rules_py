"""Build A using B and A's outgoing dependency C, without A itself installed."""

from __future__ import annotations

import base64
import hashlib
from importlib.util import find_spec
from pathlib import Path
from zipfile import ZipFile


def build_wheel(
    wheel_directory: str,
    config_settings: dict[str, object] | None = None,
    metadata_directory: str | None = None,
) -> str:
    import self_exclusion_b
    import self_exclusion_c

    assert self_exclusion_b.VALUE == "b"
    assert self_exclusion_c.VALUE == "c"
    assert find_spec("self_exclusion_a") is None

    dist_info = "self_exclusion_a-0.0.1.dist-info"
    files = {
        "self_exclusion_a.py": b"VALUE = 'built with b and c'\n",
        f"{dist_info}/METADATA": (
            b"Metadata-Version: 2.1\nName: self-exclusion-a\nVersion: 0.0.1\n"
        ),
        f"{dist_info}/WHEEL": (
            b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
        ),
    }
    record = []
    for name, content in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).rstrip(b"=")
        record.append(f"{name},sha256={digest.decode()},{len(content)}\n")
    record.append(f"{dist_info}/RECORD,,\n")
    files[f"{dist_info}/RECORD"] = "".join(record).encode()

    wheel_name = "self_exclusion_a-0.0.1-py3-none-any.whl"
    with ZipFile(Path(wheel_directory, wheel_name), "w") as wheel:
        for name, content in files.items():
            wheel.writestr(name, content)
    return wheel_name
