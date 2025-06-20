# buildifier: disable=module-docstring
load("//py:defs.bzl", "py_binary_rule", "py_library")

def click_cli_binary(name, deps = [], **kwargs):
    py_library(
        name = name + "_lib",
        srcs = ["//py/tests/external-deps/custom-macro:__main__.py"],
    )

    # NB: we don't use the py_binary macro here, because we want our `main` attribute to be used
    # exactly as specified here, rather than follow rules_python semantics.
    py_binary_rule(
        name = name,
        main = "//py/tests/external-deps/custom-macro:__main__.py",
        deps = deps + [
            name + "_lib",
            "@pypi//click",
        ],
        **kwargs
    )
