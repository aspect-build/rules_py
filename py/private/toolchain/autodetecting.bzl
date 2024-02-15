# buildifier: disable=module-docstring
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")

def _autodetecting_py_wrapper_impl(rctx):
    which_python = rctx.which("python3")
    if which_python == None:
        fail("Unable to locate 'python3' on the path")

    # Check if `which_python` ends up being the final binary, or it's actually a wrapper itself.
    exec_result = rctx.execute(
        [which_python] + _py_semantics.interpreter_flags + ["-c", "import sys; import os; print(os.path.realpath(sys.executable))"],
    )

    if exec_result.return_code == 0:
        which_python = exec_result.stdout.strip()
    else:
        fail("Unable to verify Python executable at '%s'" % which_python, exec_result.stderr)

    rctx.template(
        "python.sh",
        rctx.attr._python_wrapper_tmpl,
        substitutions = {
            "{{PYTHON_BIN}}": str(which_python),
        },
        executable = True,
    )

    build_content = """\
load("@rules_python//python:defs.bzl", "py_runtime", "py_runtime_pair")

py_runtime(
    name = "autodetecting_python3_runtime",
    interpreter = "@{name}//:python.sh",
    python_version = "PY3",
)

py_runtime_pair(
    name = "autodetecting_py_runtime_pair",
    py2_runtime = None,
    py3_runtime = ":autodetecting_python3_runtime",
)

toolchain(
    name = "py_toolchain",
    toolchain = ":autodetecting_py_runtime_pair",
    toolchain_type = "@bazel_tools//tools/python:toolchain_type",
)
""".format(
        name = rctx.attr.name,
    )
    rctx.file("BUILD.bazel", content = build_content)

_autodetecting_py_toolchain = repository_rule(
    implementation = _autodetecting_py_wrapper_impl,
    attrs = {
        "_python_wrapper_tmpl": attr.label(
            default = "@aspect_rules_py//py/private/toolchain:python.sh",
        ),
    },
)

def register_autodetecting_python_toolchain(name):
    """Registers a Python toolchain that will auto detect the location of Python that can be used with rules_py.

    The autodetecting Python toolchain replaces the automatically registered one under bazel, and correctly handles the
    Python virtual environment indirection created by rules_py. However it is recommended to instead use one of the prebuilt
    Python interpreter toolchains from rules_python, rather than rely on the the correct Python binary being present on the host.
    """
    _autodetecting_py_toolchain(
        name = name,
    )

    native.register_toolchains(
        "@%s//:py_toolchain" % name,
    )
