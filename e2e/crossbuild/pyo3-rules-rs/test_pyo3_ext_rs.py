"""Imports the PyO3 extension module rules_rs built and calls into it."""

import sys

import pyo3_ext_rs

assert pyo3_ext_rs.sum_as_string(2, 3) == "5", pyo3_ext_rs.sum_as_string(2, 3)
print("pyo3_ext_rs loaded from", pyo3_ext_rs.__file__, "on", sys.version)
