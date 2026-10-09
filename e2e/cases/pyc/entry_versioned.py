"""Checks that a shared py_venv is configured for the launcher's Python."""

import os
import sys

EXPECTED = {
    "test_pyc_source_python_312": (3, 12),
    "test_pyc_source_python_313": (3, 13),
    "test_pyc_python_312": (3, 12),
    "test_pyc_python_313": (3, 13),
    "test_pyc_only_python_312": (3, 12),
    "test_pyc_only_python_313": (3, 13),
}

assert sys.version_info[:2] == EXPECTED[os.environ["BAZEL_TARGET_NAME"]]
print("versioned venv ok")
