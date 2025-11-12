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
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main")
load("//py/private:py_unpacked_wheel.bzl", _py_unpacked_wheel = "py_unpacked_wheel")
load("//py/private:virtual.bzl", _resolutions = "resolutions")
load("//py/private/py_venv:defs.bzl", _py_venv_binary = "py_venv_binary")
load("//py/private/link:defs.bzl", _py_link_venv = "py_link_venv")

py_pex_binary = _py_pex_binary
py_pytest_main = _py_pytest_main

# FIXME: Badly chosen name; will be replaced/migrated
def py_venv(name, srcs = [], data = [], deps = [], imports = None, testonly = False, **kwargs):
    native.alias(
        name = name,
        actual = select({
            Label("//py/private/link:dynamic_venvs"): ":{}_dynamic".format(name),
            Label("//py/private/link:static_venvs"): ":{}_static".format(name),
        }),
        tags = ["manual"],
    )
    
    _py_link_venv(
        _py_binary,
        name = "{}_dynamic".format(name),
        srcs = srcs,
        data = data,
        deps = deps,
        imports = kwargs.get("imports"),
        tags = ["manual"],
        testonly = kwargs.get("testonly", False),
        target_compatible_with = kwargs.get("target_compatible_with", []),
    )
    
    _py_link_venv(
        _py_venv_binary,
        name = "{}_static".format(name),
        srcs = srcs,
        data = data,
        deps = deps,
        imports = kwargs.get("imports"),
        tags = ["manual"],
        testonly = kwargs.get("testonly", False),
        target_compatible_with = kwargs.get("target_compatible_with", []),
    )

py_venv_link = py_venv

py_binary_rule = _py_binary
py_test_rule = _py_test
py_library = _py_library
py_unpacked_wheel = _py_unpacked_wheel

py_image_layer = _py_image_layer

resolutions = _resolutions

def _py_binary_or_test(name, rule, srcs, main, data = [], deps = [], **kwargs):
    rule(
        name = name,
        srcs = srcs,
        main = main,
        data = data,
        deps = deps,
        **kwargs
    )

    py_venv(
        name = name + ".venv",
        srcs = srcs,
        data = data,
        deps = deps,
        **kwargs,
    )

def py_binary(name, srcs = [], main = None, **kwargs):
    """Wrapper macro for [`py_binary_rule`](#py_binary_rule).

    Creates a [py_venv](./venv.md) target to constrain the interpreter and packages used at runtime.
    Users can `bazel run [name].venv` to create this virtualenv, then use it in the editor or other tools.

    Args:
        name: Name of the rule.
        srcs: Python source files.
        main: Entry point.
            Like rules_python, this is treated as a suffix of a file that should appear among the srcs.
            If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.
        **kwargs: additional named parameters to `py_binary_rule`.
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
        pytest_main: If set, generate a [py_pytest_main](#py_pytest_main) script and use it as the main.
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
        pytest_main_target = name + ".pytest_main"
        main = pytest_main_target + ".py"
        py_pytest_main(name = pytest_main_target)
        srcs.append(main)
        deps.append(pytest_main_target)

    _py_binary_or_test(
        name = name,
        rule = _py_test,
        srcs = srcs,
        deps = deps,
        main = main,
        resolutions = resolutions,
        **kwargs
    )
