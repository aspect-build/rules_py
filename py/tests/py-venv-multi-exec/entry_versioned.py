"""Checks that a shared py_venv is configured for the launcher's Python."""

import os
import sys
import sysconfig


EXPECTED = {
    "test_python_312": ((3, 12), False),
    "test_python_313": ((3, 13), False),
    "test_python_313_freethreaded": ((3, 13), True),
    "test_python_312_gil_pinned": ((3, 12), False),
}

version, freethreaded = EXPECTED[os.environ["BAZEL_TARGET_NAME"]]
assert sys.version_info[:2] == version
# Not sys.abiflags: unavailable on Windows.
gil_disabled = sysconfig.get_config_var("Py_GIL_DISABLED") == 1
assert gil_disabled == freethreaded, sysconfig.get_config_var("Py_GIL_DISABLED")
print("versioned venv ok")
