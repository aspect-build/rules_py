"Installation for mypy aspect that visits py_library rules"

load("@aspect_rules_py//py:defs.bzl", "mypy_aspect")

mypy = mypy_aspect(
    binary = "@@//tools:mypy",
    configs = ["@@//:mypy.ini"],
)
