"""Imports the PyO3 extension module rules_rust built and calls into it."""

import sys

import pyo3_ext

assert pyo3_ext.sum_as_string(2, 3) == "5", pyo3_ext.sum_as_string(2, 3)
print("pyo3_ext loaded from", pyo3_ext.__file__, "on", sys.version)
