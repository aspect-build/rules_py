"""Probe a Python interpreter for version and platform info.

Prints a JSON object to stdout with the fields needed to construct
a rules_python-compatible toolchain implementation.
"""

import json
import sys
import sysconfig

data = {
    "major": sys.version_info.major,
    "minor": sys.version_info.minor,
    "micro": sys.version_info.micro,
    "include": sysconfig.get_path("include"),
    "implementation_name": sys.implementation.name,
}

config_vars = [
    "LDLIBRARY",
    "LIBDIR",
    "INSTSONAME",
    "PY3LIBRARY",
    "SHLIB_SUFFIX",
]
data.update(zip(config_vars, sysconfig.get_config_vars(*config_vars)))
print(json.dumps(data))
