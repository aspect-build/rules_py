"Public API re-exports"

load("//py/private/venv:venv.bzl", _py_venv = "py_venv")
load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_wheel.bzl", "py_wheel_lib")

def py_library(name, imports = ["."], **kwargs):
    """Wrapper macro for the py_library rule, setting a default for imports

    Args:
        name: name of the rule
        **kwargs: see [py_library attributes](./py_library)
    """
    _py_library(
        name = name,
        imports = imports,
        **kwargs
    )

def py_binary(name, srcs = [], main = None, imports = ["."], **kwargs):
    """Wrapper macro for the py_binary rule, setting a default for imports.

    It also creates a virtualenv to constrain the interpreter and packages used at runtime,
    you can `bazel run [name].venv` to produce this, then use it in the editor.

    Args:
        name: name of the rule
        srcs: python source files
        main: the entry point. If absent, then the first entry in srcs is used.
        imports: list of paths that this rule should contribute to the Python path.
        **kwargs: see [py_binary attributes](./py_binary)
    """

    _py_base(
        name = name,
        srcs = srcs,
        main = main,
        imports = imports,
        rule = _py_binary,
        **kwargs
    )

def py_test(name, main = None, srcs = [], imports = ["."], **kwargs):
    "Identical to py_binary, but produces a target that can be used with `bazel test`."

    _py_base(
        name = name,
        srcs = srcs,
        main = main,
        imports = imports,
        rule = _py_test,
        **kwargs
    )

def _py_base(name, main, srcs, imports, rule, **kwargs):
    if (not srcs or len(srcs) == 0) and not main:
        fail("Must provide either 'main' or at least one src in '//{pkg}:{name}'".format(
            pkg = native.package_name(),
            name = name,
        ))

    rule(
        name = name,
        srcs = srcs,
        main = main if main != None else srcs[0],
        **kwargs
    )

    _py_venv(
        name = "%s.venv" % name,
        deps = kwargs.pop("deps", []),
        imports = imports,
        srcs = srcs,
        tags = ["manual"],
    )

py_wheel = rule(
    implementation = py_wheel_lib.implementation,
    attrs = py_wheel_lib.attrs,
    provides = py_wheel_lib.provides,
)
