"""Public facade for the ``py`` package.

This file re-exports the private implementation rules and provides convenience
macros for the most common targets: ``py_binary`` and ``py_test``.

Choosing the Python version:
    The ``python_version`` attribute must refer to a python toolchain version
    which has been registered in the ``WORKSPACE`` or ``MODULE.bazel`` file.
    Configuring for ``MODULE.bazel`` may look like this::

        python = use_extension("@aspect_rules_py//py:extensions.bzl", "python")
        python.toolchain(python_version = "3.11.11", is_default = True)

Known problems:
    - Duplicate ``resolutions`` logic: ``py_binary`` and ``py_test`` both
      contain an identical block that pops ``resolutions`` from ``kwargs``
      and converts it with ``to_label_keyed_dict``. The helper
      ``_py_binary_or_test`` could perform this work, avoiding the copy-paste.
    - ``kwargs`` mutation in ``py_test``: the macro mutates the caller's dict
      in-place (``testonly = True``, ``data.append(...)``). This is a side-effect
      that is invisible to the caller.
    - Implicit auxiliary target: when ``pytest_main = True``, ``py_test``
      silently creates a ``<name>.pytest_paths`` rule. This violates the
      principle of least surprise because the user did not declare it.
    - ``_py_binary_or_test`` is a trivial passthrough with no docstring. It
      centralises invocation but adds no semantic value.
    - The module-level docstring contains a toolchain-configuration example
      that is only tangentially related to the rules defined in this file.
"""

load("//py/entry_points:py_console_script_binary.bzl", _py_console_script_binary = "py_console_script_binary")
load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")
load("//py/private:py_image_layer.bzl", _py_image_layer = "py_image_layer")
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pex_binary.bzl", _py_pex_binary = "py_pex_binary")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main", _pytest_paths = "pytest_paths")
load("//py/private:py_scie.bzl", _py_scie_binary = "py_scie_binary")
load("//py/private:py_unpacked_wheel.bzl", _py_unpacked_wheel = "py_unpacked_wheel")
load("//py/private:py_zipapp.bzl", _py_zipapp_binary = "py_zipapp_binary")
load("//py/private:virtual.bzl", _resolutions = "resolutions")
load("//py/private/toolchain:py_runtime.bzl", _aspect_py_runtime = "aspect_py_runtime")
load("//py/private/toolchain:py_runtime_pair.bzl", _aspect_py_runtime_pair = "aspect_py_runtime_pair")

py_pex_binary = _py_pex_binary
py_pytest_main = _py_pytest_main

py_scie_binary = _py_scie_binary
py_zipapp_binary = _py_zipapp_binary

py_binary_rule = _py_binary
py_test_rule = _py_test
py_library = _py_library
py_unpacked_wheel = _py_unpacked_wheel

py_image_layer = _py_image_layer

py_console_script_binary = _py_console_script_binary

aspect_py_runtime = _aspect_py_runtime
aspect_py_runtime_pair = _aspect_py_runtime_pair

resolutions = _resolutions


def _py_binary_or_test(name, rule, srcs, main, data = [], deps = [], **kwargs):
    """Invoke the underlying rule with the given arguments.

    This helper exists only to provide a single call site for both
    ``py_binary`` and ``py_test``. It performs no extra logic.

    Args:
        name: Name of the target.
        rule: The underlying rule symbol (``_py_binary`` or ``_py_test``).
        srcs: Python source files.
        main: Entry-point file.
        data: Non-Python data files.
        deps: Python dependencies.
        **kwargs: Remaining arguments forwarded verbatim to the rule.
    """
    rule(
        name = name,
        srcs = srcs,
        main = main,
        data = data,
        deps = deps,
        **kwargs
    )

def py_binary(name, srcs = [], main = None, **kwargs):
    """Convenience macro for ``py_binary_rule``.

    Normalises the ``resolutions`` attribute: if the caller passes a
    ``string -> label`` dict, it is converted to a Bazel
    ``label_keyed_string_dict`` (the attribute type expected by the
    underlying rule).

    Args:
        name: Name of the target.
        srcs: Python source files.
        main: Entry point.
            This is treated as a suffix of a file that should appear among the srcs.
            If absent, then ``[name].py`` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.
        **kwargs: Additional named parameters forwarded to ``py_binary_rule``.
    """
    resolutions = kwargs.pop("resolutions", None)
    if resolutions:
        resolutions = resolutions.to_label_keyed_dict()

    _py_binary_or_test(
        name = name,
        rule = _py_binary,
        srcs = srcs,
        main = main,
        resolutions = resolutions,
        **kwargs
    )

def py_test(name, srcs = [], main = None, pytest_main = False, **kwargs):
    """Convenience macro for ``py_test_rule``.

    Identical to ``py_binary`` except that it forces ``testonly = True`` and
    supports an optional ``pytest_main`` mode.

    When ``pytest_main`` is ``True``:
      * ``main`` must not be set.
      * A shared pytest entry point is injected.
      * An auxiliary target ``<name>.pytest_paths`` is created automatically.
        It writes the test-source directories to an args file that the shared
        pytest main reads, passing explicit search paths to pytest instead of
        relying on autodiscovery from the runfiles root.

    Args:
        name: Name of the target.
        srcs: Python source files.
        main: Entry point.
            This is treated as a suffix of a file that should appear among the srcs.
            If absent, then ``[name].py`` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.
        pytest_main: If ``True``, use a shared pytest entry point as the main.
            The deps should include the pytest package (as well as the coverage package if desired).
        **kwargs: Additional named parameters forwarded to ``py_test_rule``.
    """
    kwargs["testonly"] = True

    resolutions = kwargs.pop("resolutions", None)
    if resolutions:
        resolutions = resolutions.to_label_keyed_dict()

    deps = kwargs.pop("deps", [])
    if pytest_main:
        if main:
            fail("When pytest_main is set, the main attribute should not be set.")

        main = Label("//py/private:pytest_main.py")
        deps.append(Label("//py/private:default_pytest_main"))

        paths_target = name + ".pytest_paths"
        _pytest_paths(
            name = paths_target,
            srcs = srcs,
            testonly = True,
            tags = kwargs.get("tags", []),
        )
        data = list(kwargs.pop("data", []))
        data.append(paths_target)
        kwargs["data"] = data

    _py_binary_or_test(
        name = name,
        rule = _py_test,
        srcs = srcs,
        deps = deps,
        main = main,
        resolutions = resolutions,
        **kwargs
    )
