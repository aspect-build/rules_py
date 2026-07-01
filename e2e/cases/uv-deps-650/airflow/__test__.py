#!/usr/bin/env python3

# airflow is a top-level collision across many apache-airflow-* wheels.
# apache-airflow-core owns airflow/__init__.py (non-namespace); provider wheels
# contribute content under airflow/ without an __init__.py.

import os

# Airflow's initialization tries to create $AIRFLOW_HOME (default ~/airflow).
# Point it at Bazel's writable scratch dir so sandbox runs don't fail.
os.environ.setdefault("AIRFLOW_HOME", os.environ.get("TEST_TMPDIR", "/tmp"))

# apache-airflow-core: the wheel that owns airflow/__init__.py
from airflow.models import DAG

assert DAG is not None

# apache-airflow-providers-common-sql is a transitive dep of core.
# Importing from it exercises that provider content is accessible alongside
# core's airflow/__init__.py under the mixed regular/namespace topology.
from airflow.providers.common.sql.hooks.sql import DbApiHook

assert DbApiHook is not None

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
