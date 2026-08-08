import csv
import sys
from pathlib import Path

import numpy

# tritonclient 2.41.0 stores its importable package under `.data/purelib`.
import tritonclient.grpc.aio

# NumPy 1.26.4 ships bytecode that WhlInstall replaces during precompilation.
site_packages = Path(numpy.__file__).parent.parent
bytecode = (
    site_packages
    / "numpy"
    / "distutils"
    / "__pycache__"
    / f"conv_template.{sys.implementation.cache_tag}.pyc"
)
assert bytecode.is_file()
record_path = next(site_packages.glob("numpy-*.dist-info/RECORD"))
with record_path.open(newline="", encoding="utf-8") as record:
    rows = {path: (record_digest, size) for path, record_digest, size in csv.reader(record)}
# The wheel's own row went with the bytecode it described, and bytecode compiled
# during the install is never recorded, so nothing lists this file. A row would
# have to be rewritten every time compilation replaces what the wheel shipped.
assert bytecode.relative_to(site_packages).as_posix() not in rows
