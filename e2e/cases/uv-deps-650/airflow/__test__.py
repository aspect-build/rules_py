#!/usr/bin/env python3

# TODO: Deprecated API, need an alternative
import pkgutil

# `airflow` resolves to the providing wheel's natural runfiles path; the venv
# references wheels there rather than copying them into its own tree. `airflow`
# is a top-level collision across many apache-airflow-* wheels, so resolution
# must pick airflow-core (the wheel that owns `airflow/__init__.py`), not a
# provider.
_airflow_file = pkgutil.get_loader("airflow").get_filename()
assert _airflow_file.endswith("/site-packages/airflow/__init__.py"), _airflow_file
assert "apache_airflow_core" in _airflow_file, _airflow_file

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
