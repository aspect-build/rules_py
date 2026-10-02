"""Imports the PyO3 extension module rules_rust_pyo3 built and calls into it."""

import sys

import pyo3_ext_rr

assert pyo3_ext_rr.sum_as_string(2, 3) == "5", pyo3_ext_rr.sum_as_string(2, 3)
print("pyo3_ext_rr loaded from", pyo3_ext_rr.__file__, "on", sys.version)
