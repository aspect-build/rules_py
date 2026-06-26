#!/usr/bin/env python3

from importlib.util import find_spec
from pathlib import Path

# `airflow` is a top-level collision across airflow-core and several
# provider wheels. The venv must materialize one merged package directory:
# the core package keeps its own modules and provider-only children remain
# visible below the same regular package.
_airflow = find_spec("airflow")
assert _airflow is not None, _airflow
assert _airflow.origin is not None, _airflow
assert _airflow.origin.endswith("/site-packages/airflow/__init__.py"), _airflow.origin

_airflow_dir = Path(_airflow.origin).parent
for _path in [
    "configuration.py",
    "providers/common/sql/hooks/sql.py",
    "providers/standard/operators/bash.py",
]:
    assert (_airflow_dir / _path).is_file(), _path

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
