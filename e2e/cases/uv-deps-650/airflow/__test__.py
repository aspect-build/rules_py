#!/usr/bin/env python3

# Verify airflow is importable from the installed wheel
import importlib.util
spec = importlib.util.find_spec("airflow")
assert spec is not None, "airflow package should be importable"
assert spec.origin is not None, "airflow should have an origin path"

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
