"""Public entry point for current_py_toolchain rule."""

load("//py/private/interpreter:current_py_toolchain.bzl", _current_py_toolchain = "current_py_toolchain")

current_py_toolchain = _current_py_toolchain
