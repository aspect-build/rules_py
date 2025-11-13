"""Implementation for the py_binary and py_test rules."""

load(":py_venv.bzl", _py_venv = "py_venv", _py_venv_binary = "py_venv_binary", _py_venv_test = "py_venv_test")

py_venv = _py_venv
py_venv_binary = _py_venv_binary
py_venv_test = _py_venv_test
