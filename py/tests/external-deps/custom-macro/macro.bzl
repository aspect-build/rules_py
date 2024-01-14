# buildifier: disable=module-docstring
load("//py:defs.bzl", "py_binary")

def click_cli_binary(name, deps = [], **kwargs):
    py_binary(
        name = name,
        main = "//py/tests/external-deps/custom-macro:__main__.py",
        srcs = ["//py/tests/external-deps/custom-macro:__main__.py"],
        deps = deps + [
            "@pypi_click//:pkg",
        ],
        **kwargs
    )
