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
load("//py/private:py_info.bzl", _PyInfo = "PyInfo")
load(
    "//py/private:py_info_interop.bzl",
    _RulesPythonPyInfo = "RulesPythonPyInfo",
    _get_py_info = "get_py_info",
    _has_py_info = "has_py_info",
)
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pex_binary.bzl", _py_pex_binary = "py_pex_binary")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main", _pytest_paths = "pytest_paths")
load("//py/private:py_unpacked_wheel.bzl", _py_unpacked_wheel = "py_unpacked_wheel")
load("//py/private:virtual.bzl", _resolutions = "resolutions")
load("//py/private/interpreter:current_py_toolchain.bzl", _current_py_toolchain = "current_py_toolchain")
load(
    "//py/private/py_venv:defs.bzl",
    _py_binary_with_venv = "py_binary_with_venv",
    _py_venv = "py_venv",
    _py_venv_exec = "py_venv_exec",
    _py_venv_exec_test = "py_venv_exec_test",
    _py_venv_link = "py_venv_link",
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

# The PyInfo provider used by rules_py
PyInfo = _PyInfo
RulesPythonPyInfo = _RulesPythonPyInfo
get_py_info = _get_py_info
has_py_info = _has_py_info

resolutions = _resolutions

def _resolve_main(name, srcs, main):
    """Macro-time fallback for `main`. Operates on label strings instead
    of files because srcs no longer reaches the underlying rule. Order:

    1. Use `main` if set.
    2. If `srcs` has exactly one entry, use it.
    3. Look for a `<basename(name)>.py` suffix match in srcs.
    """
    if main != None:
        return main
    if len(srcs) == 1:
        return srcs[0]
    proposed = name.split("/")[-1] + ".py"
    matches = [s for s in srcs if _label_endswith(s, proposed)]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        fail("py_binary {}: file '{}' matches multiple srcs: {}".format(name, proposed, [str(m) for m in matches]))
    fail("py_binary {} has multiple srcs and no `main =`. Set main explicitly.".format(name))

def _label_endswith(label_or_str, suffix):
    s = str(label_or_str)
    return s == suffix or s.endswith(":" + suffix) or s.endswith("/" + suffix)

def py_binary(name, srcs = [], main = None, **kwargs):
    """Build and run a Python binary.

    Splits the call into a sibling `py_venv` (which carries srcs / deps
    / imports / virtual_deps / resolutions / package_collisions /
    include_*_site_packages / interpreter_options) plus a thin launcher
    rule that exec's that venv's interpreter. Set `expose_venv = True`
    to make the sibling a first-class `:{name}.venv` target — runnable
    (`bazel run :{name}.venv` drops into the hermetic interpreter) and
    pairable with `py_venv_link` for IDE integration. For the common
    case where you want both the venv target *and* an IDE-pointable
    workspace symlink in one step, set `expose_venv_link = True`.

    Args:
        name: Name of the rule.
        srcs: Python source files.
        main: Entry point.
            Like rules_python, this is treated as a suffix of a file that should appear among the srcs.
            If absent, then `[name].py` is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.

            Note: the fallback runs at macro-evaluation time and operates
            on label strings, not resolved files — it cannot inspect a
            generated target's output basename. If `main` would resolve
            to a file produced by another rule (e.g. a `genrule` whose
            output happens to be `<name>.py`), the macro can't see that
            and you must pass `main =` explicitly.
        **kwargs: additional named parameters forwarded to the
            underlying rule and the sibling py_venv. Two extras are
            handled by this macro:

            * `expose_venv` (bool, default `False`) — when `True`, emit
              a sibling `:{name}.venv` py_venv carrying all venv-shaping
              attrs (deps, imports, package_collisions,
              include_*_site_packages, interpreter_options). The `.venv`
              target is runnable (`bazel run :{name}.venv` drops into
              the hermetic interpreter).
            * `expose_venv_link` (bool, default `False`) — when `True`,
              additionally emit a `:{name}.venv_link` py_venv_link.
              `bazel run :{name}.venv_link` links the target's runfiles
              tree into the workspace and prints the nested venv path
              suitable for an IDE's interpreter setting. Implies
              `expose_venv = True`; passing
              `expose_venv = False, expose_venv_link = True` explicitly
              is rejected with a clear error. Equivalent to declaring an
              explicit
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
        name = name,
        srcs = srcs,
        main = _resolve_main(name, srcs, main),
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
        name = name,
        srcs = srcs,
        deps = deps,
        main = _resolve_main(name, srcs, main),
        resolutions = resolutions,
        **kwargs
    )
