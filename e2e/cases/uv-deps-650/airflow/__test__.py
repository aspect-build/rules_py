#!/usr/bin/env python3

# TODO: Deprecated API, need an alternative
import pkgutil
assert "cases/uv-deps-650/airflow/.airflow/" in pkgutil.get_loader("airflow").get_filename()

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 13
