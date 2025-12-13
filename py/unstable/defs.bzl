"""
Preview features.

Unstable rules and preview machinery.
No promises are made about compatibility across releases.
"""

load("//py/private/py_venv:defs.bzl", _bin = "py_venv_binary", _test = "py_venv_test", _venv = "py_venv")

py_venv = _venv
py_venv_binary = _bin
py_venv_test = _test
