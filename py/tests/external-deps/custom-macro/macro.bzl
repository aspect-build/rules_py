# buildifier: disable=module-docstring
load("//py:defs.bzl", "py_binary", "py_library")

def click_cli_binary(name, deps = [], **kwargs):
    py_library(
        name = name + "_lib",
        srcs = ["//py/tests/external-deps/custom-macro:__main__.py"],
        deps = ["@pypi_click//:pkg"],
    )

    py_binary(
        name = name,
        main = "//py/tests/external-deps/custom-macro:__main__.py",
        deps = deps + [name + "_lib"],
        **kwargs
    )
