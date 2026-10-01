"""Asserts a @rules_python py_library dependency ships as source whatever its
own precompilation settings. Files are checked before the import so the
interpreter cannot have written the cache itself.
"""

import os
import sys

root = os.path.join(os.environ["TEST_SRCDIR"], os.environ["TEST_WORKSPACE"])
source = os.path.join(root, "precompiled_lib.py")
pycache = os.path.join(
    root, "__pycache__", "precompiled_lib.{}.pyc".format(sys.implementation.cache_tag)
)
sourceless = os.path.join(root, "precompiled_lib.pyc")

present = {p for p in (source, pycache, sourceless) if os.path.exists(p)}
assert present == {source}, present

import precompiled_lib  # noqa: E402

assert precompiled_lib.answer() == 42
print("OK")
