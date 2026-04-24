"""Wrapper macro that includes dev dependencies based on a build mode flag."""

load("@aspect_rules_py//py:defs.bzl", _py_binary = "py_binary")

def py_dev_binary(name, deps = [], dev_deps = [], **kwargs):
    """A py_binary that includes dev_deps unless --//:mode=prod.

    The default mode is "dev": all dependencies (including dev_deps) are
    linked.  In release/prod mode the dev_deps are stripped.

    The active venv is controlled separately via --@pypi//venv (see
    .bazelrc) so that the hub makes the right set of packages available.

    Args:
        name: Target name.
        deps: Production dependencies — always included.
        dev_deps: Development-only dependencies — included unless mode=prod.
        **kwargs: Forwarded to py_binary.
    """
    _py_binary(
        name = name,
        deps = deps + select({
            "//:is_prod": [],
            "//conditions:default": dev_deps,
        }),
        **kwargs
    )
