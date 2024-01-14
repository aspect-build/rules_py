"Public API re-exports"

load("//py/private:py_binary.bzl", _py_binary = "py_binary", _py_test = "py_test")
load("//py/private:py_executable.bzl", "determine_main")
load("//py/private:py_library.bzl", _py_library = "py_library")
load("//py/private:py_pytest_main.bzl", _py_pytest_main = "py_pytest_main")
load("//py/private:py_wheel.bzl", "py_wheel_lib")
load("//py/private/venv:venv.bzl", _py_venv = "py_venv")

py_pytest_main = _py_pytest_main
py_venv = _py_venv
py_binary_rule = _py_binary
py_test_rule = _py_test
py_library_rule = _py_library

_a_struct_type = type(struct())
_a_string_type = type("")

def _py_binary_or_test(name, rule, srcs, main, imports, deps = [], resolutions = {}, **kwargs):
    if not main and not len(srcs):
        fail("When 'main' is not specified, 'srcs' must be non-empty")
    rule(
        name = name,
        srcs = srcs,
        main = main if main != None else srcs[0],
        imports = imports,
        deps = deps,
        resolutions = resolutions,
        **kwargs
    )

    _py_venv(
        name = "%s.venv" % name,
        deps = deps,
        imports = imports,
        srcs = srcs,
        resolutions = resolutions,
        tags = ["manual"],
    )

def py_binary(name, srcs = [], main = None, imports = ["."], resolutions = {}, **kwargs):
    """Wrapper macro for [`py_binary_rule`](#py_binary_rule), setting a default for imports.

    It also creates a virtualenv to constrain the interpreter and packages used at runtime,
    you can `bazel run [name].venv` to produce this, then use it in the editor.

    Args:
        name: name of the rule
        srcs: python source files
        main: the entry point. If absent, then the first entry in srcs is used. If srcs is non-empty,
            then this is treated as a suffix of a file that should appear among the srcs.
        imports: List of import paths to add for this binary.
        resolutions: FIXME
        **kwargs: additional named parameters to the py_binary_rule
    """

    deps = kwargs.pop("deps", [])
    concrete = []

    # For a clearer DX when updating resolutions, the resolutions dict is "string" -> "label",
    # where the rule attribute is a label-typed-dict, so reverse them here.
    resolutions = {v: k for k, v in resolutions.items()}

    # Compatibility with rules_python, see docs on find_main
    if not main or main and srcs:
        main_target = "_{}.find_main".format(name)
        determine_main(
            name = main_target,
            main = main,
            srcs = srcs,
        )
        main = main_target

    for dep in deps:
        if type(dep) == _a_struct_type:
            if dep.virtual:
                fail("only non-virtual deps are allowed at a py_binary or py_test rule")
            else:
                # constraint here must be concrete, ie == or no specifier
                resolutions.update([["@{}_{}//:wheel".format(dep.prefix, "foo"), dep.name]])
        elif type(dep) == _a_string_type:
            concrete.append(dep)
        else:
            fail("dep element {} is of type {} but should be a struct or a string".format(
                dep,
                type(dep),
            ))

    _py_binary_or_test(name = name, rule = _py_binary, srcs = srcs, main = main, imports = imports, resolutions = resolutions, deps = concrete, **kwargs)

def py_test(name, main = None, srcs = [], imports = ["."], **kwargs):
    "Identical to py_binary, but produces a target that can be used with `bazel test`."
    _py_binary_or_test(name = name, rule = _py_test, srcs = srcs, main = main, imports = imports, **kwargs)

py_wheel = rule(
    implementation = py_wheel_lib.implementation,
    attrs = py_wheel_lib.attrs,
    provides = py_wheel_lib.provides,
)

def resolutions(base, overrides = {}):
    return dict(base, **overrides)

def make_dep_helper(prefix = "pypi"):
    """Returns a function that assists in making dependency references when using virtual dependencies.

    Args:
        prefix: The prefix to attach to all dependency labels, representing the external repository that the external dependency is defined in.
    """

    return lambda name, **kwargs: dep(name, prefix = prefix, **kwargs)

def dep(name, *, virtual = False, constraint = None, prefix = "pypi", default = None, from_label = None):
    """Creates a Python dependency reference from the libraries name.

    Args:
        name: Name of the dependency to include
        virtual: If true, the dependency is considered "virtual", and the terminal py_* rule must provide a concrete dependency label
        constraint: If the dependency is considered virtual, provide an optional constraint over the version range that the virtual dependency can be satisfied by.
        prefix: The dependency label prefix, defaults to "pypi"
        default: Default target that will provide this dependency if none is provided at the terminal rule.
        from_label: When given in conjunction with name, maps the name to a concrete dependency label, can be used to override the default resolved via this helper.
    """

    return struct(
        name = name,
        virtual = virtual,
        constraint = constraint,
        prefix = prefix,
        default = default,
        from_label = from_label,
    )

def py_library(name, imports = ["."], deps = [], **kwargs):
    """Wrapper macro for the [py_library_rule](./py_library_rule), supporting virtual deps.

    Args:
        name: name of resulting py_library_rule
        imports: List of import paths to add for this library.
        deps: Dependencies for this Python library.
        **kwargs: additional named parameters to py_library_rule
    """

    concrete = []
    virtual = []

    # Allow users to pass a list of virtual dependencies via the virtual attr.
    virtual.extend(kwargs.pop("virtual_deps", []))

    for dep in deps:
        if type(dep) == _a_struct_type:
            # { name: "requests", virtual = True | False, constraint = "" }
            if dep.virtual:
                # deal with constraint
                virtual.append(dep.name)
            else:
                if dep.constraint:
                    fail("Illegal constraint on a non-virtual dependency")
                if dep.from_label:
                    concrete.append(dep.from_label)
                else:
                    # FIXME: looks like this may not work with bzlmod where the naming convention is different?
                    concrete.append("@{}_{}//:wheel".format(dep.prefix, dep.name))
        elif type(dep) == _a_string_type:
            concrete.append(dep)
        else:
            fail("dep element {} is of type {} but should be a struct or a string".format(
                dep,
                type(dep),
            ))

    py_library_rule(
        name = name,
        deps = concrete,
        virtual_deps = virtual,
        imports = imports,
        **kwargs
    )
