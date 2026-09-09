"""One checked-in source listed by both a rules_py and a rules_python library."""

import importlib
import os

module = importlib.import_module(os.environ["SHARED_MODULE"])
assert module.SHARED == "shared"
print("OK")
