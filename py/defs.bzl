"Public API re-exports"

load("@aspect_bazel_lib//lib:utils.bzl", "propagate_common_rule_attributes")
load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")
load("//py/private:py_executable.bzl", "determine_main")
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main")
load("//py/private:py_unpacked_wheel.bzl", _py_unpacked_wheel = "py_unpacked_wheel")
load("//py/private:virtual.bzl", _resolutions = "resolutions")
load("//py/private:py_venv.bzl", _py_venv = "py_venv")

py_pytest_main = _py_pytest_main

py_venv = _py_venv
py_binary_rule = _py_binary
py_test_rule = _py_test
py_library_rule = _py_library
py_unpacked_wheel_rule = _py_unpacked_wheel

resolutions = _resolutions

def _py_binary_or_test(name, rule, srcs, main, imports, deps = [], resolutions = {}, **kwargs):
    # Compatibility with rules_python, see docs in py_executable.bzl
    main_target = "_{}.find_main".format(name)
    determine_main(
        name = main_target,
        target_name = name,
        main = main,
        srcs = srcs,
        **propagate_common_rule_attributes(kwargs)
    )

    rule(
        name = name,
        srcs = srcs,
        main = main_target,
        imports = imports,
        deps = deps,
        resolutions = resolutions,
        **kwargs
    )

    _py_venv(
        name = "{}.venv".format(name),
        deps = deps,
        imports = imports,
        resolutions = resolutions,
        tags = ["manual"],
    )

def py_binary(name, srcs = [], main = None, imports = [], **kwargs):
    """Wrapper macro for [`py_binary_rule`](#py_binary_rule), setting a default for imports.

    It also creates a virtualenv to constrain the interpreter and packages used at runtime,
    you can `bazel run [name].venv` to produce this, then use it in the editor.

    Args:
        name: Name of the rule.
        srcs: Python source files.
        main: Entry point.
            Like rules_python, this is treated as a suffix of a file that should appear among the srcs.
            If absent, then "[name].py" is tried. As a final fallback, if the srcs has a single file,
            that is used as the main.
        imports: List of import paths to add for this binary.
        **kwargs: additional named parameters to the py_binary_rule.
    """

    # For a clearer DX when updating resolutions, the resolutions dict is "string" -> "label",
    # where the rule attribute is a label-keyed-dict, so reverse them here.
    resolutions = kwargs.pop("resolutions", None)
    if resolutions:
        resolutions = resolutions.to_label_keyed_dict()

    _py_binary_or_test(name = name, rule = _py_binary, srcs = srcs, main = main, imports = imports, resolutions = resolutions, **kwargs)

def py_test(name, main = None, srcs = [], imports = [], **kwargs):
    "Identical to py_binary, but produces a target that can be used with `bazel test`."

    # Ensure that any other targets we write will be testonly like the py_test target
    kwargs["testonly"] = True
    _py_binary_or_test(name = name, rule = _py_test, srcs = srcs, main = main, imports = imports, **kwargs)

def py_library(name, imports = [], **kwargs):
    """Wrapper macro for the [py_library_rule](./py_library_rule), supporting virtual deps.

    Args:
        name: Name for this rule.
        imports: List of import paths to add for this library.
        **kwargs: Additional named parameters to py_library_rule.
    """

    _py_library(name = name, imports = imports, **kwargs)

def py_unpacked_wheel(name, **kwargs):
    """Wrapper macro for the [py_unpacked_wheel_rule](#py_unpacked_wheel_rule), setting a defaults.

    Args:
        name: Name of this rule.
        **kwargs: Additional named parameters to py_unpacked_wheel_rule.
    """

    _py_unpacked_wheel(name = name, **kwargs)
