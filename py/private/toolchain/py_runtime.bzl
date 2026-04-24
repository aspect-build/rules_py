"""Custom py_runtime rule that emits AspectPyRuntimeInfo.

This replaces @rules_python//python:py_runtime to remove the dependency
on rules_python runtime rules.
"""

AspectPyRuntimeInfo = provider(
    doc = "Information about a Python runtime, compatible with rules_py toolchain consumers.",
    fields = {
        "interpreter": "The interpreter File, or None if using interpreter_path.",
        "interpreter_path": "Absolute path to the interpreter, or None if using interpreter File.",
        "files": "depset of Files required at runtime.",
        "interpreter_version_info": "struct with major, minor, micro string fields.",
        "python_version": "Python version string, e.g. 'PY3'.",
    },
)

def _aspect_py_runtime_impl(ctx):
    interpreter = ctx.file.interpreter
    interpreter_path = ctx.attr.interpreter_path
    files = ctx.files.files

    if interpreter and interpreter_path:
        fail("Only one of interpreter or interpreter_path may be set")
    if not interpreter and not interpreter_path:
        fail("One of interpreter or interpreter_path must be set")

    version_info = ctx.attr.interpreter_version_info
    if not version_info:
        fail("interpreter_version_info is required")
    for attr in ["major", "minor", "micro"]:
        if attr not in version_info:
            fail("interpreter_version_info must contain '{}'".format(attr))

    runtime_info = AspectPyRuntimeInfo(
        interpreter = interpreter,
        interpreter_path = interpreter_path,
        files = depset(files),
        interpreter_version_info = struct(
            major = str(version_info["major"]),
            minor = str(version_info["minor"]),
            micro = str(version_info["micro"]),
        ),
        python_version = ctx.attr.python_version,
    )

    if interpreter:
        all_files = depset([interpreter], transitive = [depset(files)])
    else:
        all_files = depset(files)

    return [
        DefaultInfo(files = all_files),
        runtime_info,
    ]

aspect_py_runtime = rule(
    implementation = _aspect_py_runtime_impl,
    doc = """Declares a Python runtime for use with rules_py toolchains.

This is a drop-in replacement for rules_python's py_runtime that emits
AspectPyRuntimeInfo instead of PyRuntimeInfo.
""",
    attrs = {
        "interpreter": attr.label(
            doc = "The Python interpreter binary.",
            allow_single_file = True,
        ),
        "interpreter_path": attr.string(
            doc = "Absolute path to the interpreter binary. Use either this or interpreter, not both.",
        ),
        "files": attr.label_list(
            doc = "Files required at runtime.",
            allow_files = True,
        ),
        "interpreter_version_info": attr.string_dict(
            doc = """Version information for the interpreter. Must include 'major', 'minor', and 'micro'.

For example:
    {"major": "3", "minor": "11", "micro": "6"}
""",
            mandatory = True,
        ),
        "python_version": attr.string(
            doc = "Python version string.",
            default = "PY3",
            values = ["PY2", "PY3"],
        ),
    },
    provides = [AspectPyRuntimeInfo],
)
