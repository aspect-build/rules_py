import csv
import hashlib
import sys
from base64 import urlsafe_b64encode
from pathlib import Path

import numpy

# tritonclient 2.41.0 stores its importable package under `.data/purelib`.
import tritonclient.grpc.aio

# NumPy 1.26.4 ships bytecode that compileall can replace during WhlInstall.
site_packages = Path(numpy.__file__).parent.parent
bytecode = (
    site_packages
    / "numpy"
    / "distutils"
    / "__pycache__"
    / f"conv_template.{sys.implementation.cache_tag}.pyc"
)
content = bytecode.read_bytes()
digest = urlsafe_b64encode(hashlib.sha256(content).digest()).decode().rstrip("=")
record_path = next(site_packages.glob("numpy-*.dist-info/RECORD"))
with record_path.open(newline="", encoding="utf-8") as record:
    rows = {path: (record_digest, size) for path, record_digest, size in csv.reader(record)}
assert rows[bytecode.relative_to(site_packages).as_posix()] == (
    f"sha256={digest}",
    str(len(content)),
)
