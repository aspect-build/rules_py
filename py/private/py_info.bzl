"""The `PyInfo` provider used by rules_py.

This is the single seam through which rules_py imports `PyInfo`. Today it simply
re-exports `@rules_python//python:defs.bzl%PyInfo`; centralising the import here
means a future change to rules_py's own provider only touches this file, not
every load site. Re-exported from `//py:defs.bzl` as public API.
"""

load("@rules_python//python:defs.bzl", _PyInfo = "PyInfo")

PyInfo = _PyInfo
