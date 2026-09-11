"""Asserts a rules_py binary ships a @rules_python py_library dependency's
sources or bytecode as the bytecode mode dictates. Files are checked before the
import so the interpreter cannot have written the cache itself.

rules_python keeps the library's srcs in its own runfiles, so pyc_only only
drops the source when rules_python's omit_source retention drops it too.
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
legacy = os.path.join(root, "precompiled_lib.pyc")

present = {p for p in (source, pycache, legacy) if os.path.exists(p)}
expected = {
    "source": {source},
    "pyc": {source, pycache},
    "pyc_only": {legacy} | ({source} if source_in_runfiles else set()),
}[mode]
assert present == expected, (mode, present)

import precompiled_lib  # noqa: E402

assert precompiled_lib.answer() == 42
print("OK")
