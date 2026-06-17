"""Re-implementations of [py_binary](https://bazel.build/reference/be/python#py_binary)
and [py_test](https://bazel.build/reference/be/python#py_test)

## Choosing the Python version

The `python_version` attribute must refer to a python toolchain version
which has been registered in the `MODULE.bazel` file, e.g.:

```starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.8.12", is_default = False)
python.toolchain(python_version = "3.9", is_default = True)
```
"""

load(
    "//py/private:py_image_layer.bzl",
    _PyLayerTierInfo = "PyLayerTierInfo",
    _py_image_layer = "py_image_layer",
    _py_layer_tier = "py_layer_tier",
)
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pex_binary.bzl", _py_pex_binary = "py_pex_binary")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main", _pytest_paths = "pytest_paths")
load("//py/private:py_unpacked_wheel.bzl", _py_unpacked_wheel = "py_unpacked_wheel")
load("//py/private:virtual.bzl", _resolutions = "resolutions")
load("//py/private/interpreter:current_py_toolchain.bzl", _current_py_toolchain = "current_py_toolchain")
load(
    "//py/private/py_venv:py_venv.bzl",
    _py_binary_with_venv = "py_binary_with_venv",
    _py_venv = "py_venv",
    _py_venv_link = "py_venv_link",
)
load(
    "//py/private/py_venv:py_venv_exec.bzl",
    _py_binary_direct = "py_binary_direct",
    _py_direct_test = "py_direct_test",
    _py_venv_exec = "py_venv_exec",
    _py_venv_exec_test = "py_venv_exec_test",
)

current_py_toolchain = _current_py_toolchain
py_pex_binary = _py_pex_binary
py_pytest_main = _py_pytest_main

py_venv = _py_venv
py_venv_link = _py_venv_link

py_library = _py_library
py_unpacked_wheel = _py_unpacked_wheel

py_image_layer = _py_image_layer
py_layer_tier = _py_layer_tier
PyLayerTierInfo = _PyLayerTierInfo

resolutions = _resolutions

def py_binary(name, srcs = [], main = None, **kwargs):
    """Build and run a Python binary.

    Creates one direct configured target with a private runtime venv.
    Set `expose_venv = True` to emit a physical sibling
    `:{name}.venv` target that is runnable (`bazel run :{name}.venv`
    drops into the hermetic interpreter) and pairable with
    `py_venv_link` for IDE integration. Set `expose_venv_link = True`
    to create both the exposed venv and a workspace-local interpreter
    symlink.

    Args:
        name: Name of the rule.
        srcs: Python source files.
        main: Entry point.
            Like rules_python, this is treated as a suffix of a file that should appear among the srcs.
            If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.

        **kwargs: additional named parameters forwarded to the selected
            direct or exposed implementation. Two extras are handled by
            this macro:

            * `expose_venv` (bool, default `False`) — when `True`, emit
              a sibling `:{name}.venv` py_venv carrying all venv-shaping
              attrs (deps, imports, package_collisions,
              include_*_site_packages, interpreter_options). The `.venv`
              target is runnable (`bazel run :{name}.venv` drops into
              the hermetic interpreter).
            * `expose_venv_link` (bool, default `False`) — when `True`,
              additionally emit a `:{name}.venv_link` py_venv_link.
              `bazel run :{name}.venv_link` materialises a
              workspace-local symlink to the venv tree, suitable for an
              IDE's interpreter setting. Implies `expose_venv = True`;
              passing `expose_venv = False, expose_venv_link = True`
              explicitly is rejected with a clear error. Equivalent to
              declaring an explicit
              `py_venv_link(name = "{name}.venv_link", venv = ":{name}.venv")`
              alongside the binary.
    """

    # For a clearer DX when updating resolutions, the resolutions dict is "string" -> "label",
    # where the rule attribute is a label-keyed-dict, so reverse them here.
    resolutions = kwargs.pop("resolutions", None)
    if resolutions:
        resolutions = resolutions.to_label_keyed_dict()

    _py_binary_with_venv(
        _py_venv_exec,
        _py_binary_direct,
        name = name,
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
        **kwargs: additional named parameters forwarded to the
            underlying rule and the sibling py_venv.
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

    _py_binary_with_venv(
        _py_venv_exec_test,
        _py_direct_test,
        name = name,
        srcs = srcs,
        deps = deps,
        main = main,
        resolutions = resolutions,
        **kwargs
    )
