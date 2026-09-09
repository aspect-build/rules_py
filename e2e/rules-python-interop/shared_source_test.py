"""One checked-in source listed by both a rules_py and a rules_python library.

EXPECT_FLAGS names the PEP 552 flags of the bytecode CPython loads: rules_python
precompiles checked-hash (3) here and rules_py unchecked-hash (1), so it shows
which ruleset's file was shipped.
"""

import importlib
import os

module = importlib.import_module(os.environ["SHARED_MODULE"])
assert module.SHARED == "shared"

expected = os.environ.get("EXPECT_FLAGS")
if expected:
    path = module.__file__ if module.__file__.endswith(".pyc") else module.__cached__
    with open(path, "rb") as f:
        flags = int.from_bytes(f.read(8)[4:8], "little")
    assert flags == int(expected), (path, flags)
print("OK")
