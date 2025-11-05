load("//py:defs.bzl", "py_library")
load("@with_cfg.bzl", "with_cfg")

py_whl_library, _ = with_cfg(py_library).set(Label("//uv/private/constraints:lib_mode"), "whl").build()
