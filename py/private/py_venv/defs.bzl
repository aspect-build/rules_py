"""Re-exports of the public API for the ``py_venv`` package.

External consumers should load from ``//py/private/py_venv:defs.bzl``
instead of individual ``.bzl`` files.
"""

load(
    ":py_venv.bzl",
    _py_binary_with_venv = "py_binary_with_venv",
    _py_venv = "py_venv",
    _py_venv_link = "py_venv_link",
)
load(
    ":py_venv_exec.bzl",
    _py_venv_exec = "py_venv_exec",
    _py_venv_exec_test = "py_venv_exec_test",
)
load(
    ":types.bzl",
    _VirtualenvInfo = "VirtualenvInfo",
    _venv_root = "venv_root",
)

py_venv = _py_venv
py_venv_link = _py_venv_link
py_binary_with_venv = _py_binary_with_venv
py_venv_exec = _py_venv_exec
py_venv_exec_test = _py_venv_exec_test
VirtualenvInfo = _VirtualenvInfo
venv_root = _venv_root
