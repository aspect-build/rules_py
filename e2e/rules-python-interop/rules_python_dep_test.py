"""Asserts which files of a @rules_python py_library dependency ship per bytecode
mode. Files are checked before the import so the interpreter cannot have
written the cache itself.
"""

import os
import sys

mode = os.environ.get("EXPECT_PYC", "source")
source_in_runfiles = os.environ.get("EXPECT_SOURCE_IN_RUNFILES") == "1"
root = os.path.join(os.environ["TEST_SRCDIR"], os.environ["TEST_WORKSPACE"])
source = os.path.join(root, "precompiled_lib.py")
pycache = os.path.join(
    root, "__pycache__", "precompiled_lib.{}.pyc".format(sys.implementation.cache_tag)
)
sourceless = os.path.join(root, "precompiled_lib.pyc")

present = {p for p in (source, pycache, sourceless) if os.path.exists(p)}
expected = {
    "source": {source},
    "pyc": {source, pycache},
    "pyc_only": {sourceless} | ({source} if source_in_runfiles else set()),
}[mode]
assert present == expected, (mode, present)

import precompiled_lib  # noqa: E402

assert precompiled_lib.answer() == 42
assert precompiled_lib.debug(), "dependency bytecode was compiled with optimization"
print("OK")
