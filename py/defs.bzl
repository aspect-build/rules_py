"""Re-implementations of [py_binary](https://bazel.build/reference/be/python#py_binary)
and [py_test](https://bazel.build/reference/be/python#py_test)

## Choosing the Python version

The `python_version` attribute must refer to a python toolchain version
which has been registered in the WORKSPACE or MODULE.bazel file.

When using WORKSPACE, this may look like this:

```starlark
load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain_3_8",
    python_version = "3.8.12",
    # setting set_python_version_constraint makes it so that only matches py_* rule
    # which has this exact version set in the `python_version` attribute.
    set_python_version_constraint = True,
)

# It's important to register the default toolchain last it will match any py_* target.
python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)
```

Configuring for MODULE.bazel may look like this:

```starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.8.12", is_default = False)
python.toolchain(python_version = "3.9", is_default = True)
```
"""

load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")
load("//py/private:py_image_layer.bzl", _py_image_layer = "py_image_layer")
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pex_binary.bzl", _py_pex_binary = "py_pex_binary")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main", _pytest_paths = "pytest_paths")
load("//py/private:py_unpacked_wheel.bzl", _py_unpacked_wheel = "py_unpacked_wheel")
load("//py/private:virtual.bzl", _resolutions = "resolutions")
load(
    "//py/private/py_venv:py_venv.bzl",
    _py_binary_with_venv = "py_binary_with_venv",
    _py_venv = "py_venv",
    _py_venv_binary = "py_venv_binary",
    _py_venv_link = "py_venv_link",
    _py_venv_test = "py_venv_test",
)

py_pex_binary = _py_pex_binary
py_pytest_main = _py_pytest_main

py_venv = _py_venv
py_venv_link = _py_venv_link

# Removed in v2.0.0: calling these `fail()`s at analysis with a
# migration message pointing at `py_binary` / `py_test` with
# `expose_venv = True, isolated = False`. Kept exported here so that
# `load("@aspect_rules_py//py:defs.bzl", "py_venv_binary")` resolves
# and the call-site failure surfaces the friendly message (instead of
# Bazel's generic "symbol not exported" error).
py_venv_binary = _py_venv_binary
py_venv_test = _py_venv_test

py_binary_rule = _py_binary
py_test_rule = _py_test
py_library = _py_library
py_unpacked_wheel = _py_unpacked_wheel

py_image_layer = _py_image_layer

resolutions = _resolutions

def _py_binary_or_test(name, rule, srcs, main, data = [], deps = [], expose_venv = False, venv_dir_basename = None, **kwargs):
    if expose_venv:
        # Split into a sibling `:{name}.venv` py_venv + a rule call
        # consuming it via `external_venv`. The `.venv` target is
        # first-class: shareable across binaries and runnable to drop
        # into the interpreter. See `py_binary_with_venv` for the
        # attribute split.
        _py_binary_with_venv(
            rule,
            name = name,
            srcs = srcs,
            main = main,
            data = data,
            deps = deps,
            venv_dir_basename = venv_dir_basename,
            **kwargs
        )
        return

    if venv_dir_basename != None:
        fail("venv_dir_basename requires expose_venv = True (no venv target is created otherwise)")

    rule(
        name = name,
        srcs = srcs,
        main = main,
        data = data,
        deps = deps,
        **kwargs
    )

def py_binary(name, srcs = [], main = None, **kwargs):
    """Wrapper macro for [`py_binary_rule`](#py_binary_rule).

    By default builds one target: the binary with an internal
    analysis-time venv. Set `expose_venv = True` to also emit a
    first-class sibling `:{name}.venv` py_venv — shareable across
    multiple binaries via `external_venv`, and runnable
    (`bazel run :{name}.venv`) to drop into the hermetic interpreter.

    Args:
        name: Name of the rule.
        srcs: Python source files.
        main: Entry point.
            Like rules_python, this is treated as a suffix of a file that should appear among the srcs.
            If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.
        **kwargs: additional named parameters to `py_binary_rule`. Two
            extras handled by this macro:

            * `expose_venv` (bool, default `False`) — when `True`, emit
              a sibling `:{name}.venv` py_venv carrying all venv-shaping
              attrs (deps, imports, package_collisions,
              include_*_site_packages, interpreter_options). The binary
              consumes it via `external_venv`. The `.venv` target is
              shareable (another `py_binary(external_venv = ":{name}.venv")`
              can point at it) and runnable (drops into interpreter).
              To also materialise the venv as a workspace-local symlink
              for IDE integration, declare an explicit `py_venv_link(
              name = "...", venv = ":{name}.venv")` target.
            * `venv_dir_basename` (str) — only valid with
              `expose_venv = True`. Controls the on-disk basename of
              the generated venv.
    """

    # For a clearer DX when updating resolutions, the resolutions dict is "string" -> "label",
    # where the rule attribute is a label-keyed-dict, so reverse them here.
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
    """Identical to [py_binary](./py_binary.md), but produces a target that can be used with `bazel test`.

    Args:
        name: Name of the rule.
        srcs: Python source files.
        main: Entry point.
            Like rules_python, this is treated as a suffix of a file that should appear among the srcs.
            If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.
        pytest_main: If True, use a shared pytest entry point as the main.
            The deps should include the pytest package (as well as the coverage package if desired).
        **kwargs: additional named parameters to `py_binary_rule`.
    """

    # Ensure that any other targets we write will be testonly like the py_test target
    kwargs["testonly"] = True

    # For a clearer DX when updating resolutions, the resolutions dict is "string" -> "label",
    # where the rule attribute is a label-keyed-dict, so reverse them here.
    resolutions = kwargs.pop("resolutions", None)
    if resolutions:
        resolutions = resolutions.to_label_keyed_dict()

    deps = kwargs.pop("deps", [])
    if pytest_main:
        if main:
            fail("When pytest_main is set, the main attribute should not be set.")

        # When pytest_main is True (no custom args/chdir), reuse the shared
        # default pytest main instead of generating a per-test copy.
        main = Label("//py/private:pytest_main.py")
        deps.append(Label("//py/private:default_pytest_main"))

        # Compute the directories containing test sources and write them
        # to an args file. The shared pytest main reads this file to pass
        # explicit search paths to pytest instead of relying on autodiscovery
        # from the runfiles root.
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
