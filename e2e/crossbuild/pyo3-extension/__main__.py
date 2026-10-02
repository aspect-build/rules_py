"""Entrypoint of the image: imports the PyO3 extension and prints its answer."""

import pyo3_ext

print(pyo3_ext.sum_as_string(2, 3))
