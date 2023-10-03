"Public API re-exports"

load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main")
load("//py/private:py_wheel.bzl", "py_wheel_lib")
load("//py/private/venv:venv.bzl", _py_venv = "py_venv")

py_library = _py_library
py_pytest_main = _py_pytest_main
py_venv = _py_venv
py_binary_rule = _py_binary
py_test_rule = _py_test

def _py_binary_or_test(name, rule, srcs, main, imports, **kwargs):
    if not main and not len(srcs):
        fail("When 'main' is not specified, 'srcs' must be non-empty")
    rule(
        name = name,
        srcs = srcs,
        main = main if main != None else srcs[0],
        imports = imports,
        **kwargs
    )

    _py_venv(
        name = "%s.venv" % name,
        deps = kwargs.pop("deps", []),
        imports = imports,
        srcs = srcs,
        tags = ["manual"],
    )

def py_binary(name, srcs = [], main = None, imports = ["."], **kwargs):
    """Wrapper macro for [`py_binary_rule`](#py_binary_rule), setting a default for imports.

    It also creates a virtualenv to constrain the interpreter and packages used at runtime,
    you can `bazel run [name].venv` to produce this, then use it in the editor.

    Args:
        name: name of the rule
        srcs: python source files
        main: the entry point. If absent, then the first entry in srcs is used.
        imports: List of import paths to add for this binary.
        **kwargs: additional named parameters to the py_binary_rule
    """
    _py_binary_or_test(name = name, rule = _py_binary, srcs = srcs, main = main, imports = imports, **kwargs)

def py_test(name, main = None, srcs = [], imports = ["."], **kwargs):
    "Identical to py_binary, but produces a target that can be used with `bazel test`."
    _py_binary_or_test(name = name, rule = _py_test, srcs = srcs, main = main, imports = imports, **kwargs)

py_wheel = rule(
    implementation = py_wheel_lib.implementation,
    attrs = py_wheel_lib.attrs,
    provides = py_wheel_lib.provides,
)
