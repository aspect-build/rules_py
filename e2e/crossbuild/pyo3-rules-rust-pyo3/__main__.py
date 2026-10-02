"""Entrypoint of the image: imports the PyO3 extension and prints its answer."""

import pyo3_ext_rr

print(pyo3_ext_rr.sum_as_string(2, 3))
