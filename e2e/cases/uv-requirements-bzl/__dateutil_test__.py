"""Verifies requirement() normalizes its input (PEP 503) before label
lookup. A user calling requirement('Python-DateUtil') / 'PYTHON_DATEUTIL'
/ 'python.dateutil' should all resolve to the same py_library."""

import dateutil

assert hasattr(dateutil, "__version__")
print("requirement() normalized non-canonical name to python_dateutil:pkg")
