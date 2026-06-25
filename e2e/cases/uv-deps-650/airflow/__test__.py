#!/usr/bin/env python3

from importlib.util import find_spec

# `airflow` is a regular package whose contents span apache-airflow-core and
# several provider wheels. The venv must expose one merged package without
# dropping provider subpackages.
airflow_spec = find_spec("airflow")
assert airflow_spec is not None
assert airflow_spec.origin is not None
assert airflow_spec.origin.endswith("/site-packages/airflow/__init__.py"), (
    airflow_spec.origin
)
for provider in (
    "airflow.providers.common.compat",
    "airflow.providers.common.io",
    "airflow.providers.common.sql",
    "airflow.providers.smtp",
    "airflow.providers.standard",
    "airflow.sdk",
):
    assert find_spec(provider) is not None, provider

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
