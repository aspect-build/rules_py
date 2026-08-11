"""Checks that a shared py_venv is configured for the launcher's Python."""

import os
import sys


EXPECTED_VERSIONS = {
    "test_pyc_python_310": (3, 10),
    "test_pyc_python_312": (3, 12),
    "test_pyc_source_python_310": (3, 10),
    "test_pyc_source_python_312": (3, 12),
    "test_pyc_only_python_310": (3, 10),
    "test_pyc_only_python_312": (3, 12),
}

assert sys.version_info[:2] == EXPECTED_VERSIONS[os.environ["BAZEL_TARGET_NAME"]]
