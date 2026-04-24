#!/usr/bin/env python3

# TODO: Deprecated API, need an alternative
import pkgutil

# airflow's install path sits under a dot-prefixed venv dir in this
# test's package. The venv basename varies by rule variant (py_test
# vs. py_venv_test), so match on the package path + hidden dir
# structure rather than the specific basename.
_airflow_file = pkgutil.get_loader("airflow").get_filename()
assert "/cases/uv-deps-650/airflow/." in _airflow_file, _airflow_file

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
