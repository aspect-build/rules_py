"""Functions to determine which Python toolchain to use"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

_INTERPRETER_FLAGS = [
    # -B     Don't write .pyc files on import. See also PYTHONDONTWRITEBYTECODE.
    "-B",
    # -I     Run Python in isolated mode. This also implies -E and -s.
    #        In isolated mode sys.path contains neither the script's directory nor the user's site-packages directory.
    #        All PYTHON* environment variables are ignored, too.
    #        Further restrictions may be imposed to prevent the user from injecting malicious code.
    "-I",
]

_MUST_SET_TOOLCHAIN_INTERPRETER_VERSION_INFO = """
ERROR: In Bazel 7.x and later, the python toolchain py_runtime interpreter_version_info must be set \
to a dict with keys "major", "minor", and "micro".

`PyRuntimeInfo` requires that this field contains the static version information for the given
interpreter. This can be set via `py_runtime` when registering an interpreter toolchain, and will
done automatically for the builtin interpreter versions registered via `python_register_toolchains`.
Note that this only available on the Starlark implementation of the provider.

For example:

    py_runtime(
        name = "system_runtime",
        interpreter_path = "/usr/bin/python",
        interpreter_version_info = {
            "major": "3",
            "minor": "11",
            "micro": "6",
        },
        python_version = "PY3",
    )
"""

def _resolve_toolchain(ctx):
    """Resolves the Python toolchain to a simple struct.

    Args:
        ctx: Bazel rule context.

    Returns:
        Struct describing the Python toolchain to use.
    """

    toolchain_info = ctx.toolchains[PY_TOOLCHAIN]

    if not toolchain_info.py3_runtime:
        fail("A py3_runtime must be set on the Python toolchain")

    py3_toolchain = toolchain_info.py3_runtime

    interpreter = None
    runfiles_interpreter = True

    if py3_toolchain.interpreter != None:
        files = depset([py3_toolchain.interpreter], transitive = [py3_toolchain.files])
        interpreter = py3_toolchain.interpreter
    else:
        files = py3_toolchain.files
        interpreter = struct(
            path = py3_toolchain.interpreter_path,
            short_path = py3_toolchain.interpreter_path,
        )
        files = depset([])
        runfiles_interpreter = False

    # Bazel 7 has this field on the PyRuntimeInfo
    if hasattr(py3_toolchain, "interpreter_version_info"):
        for attr in ["major", "minor", "micro"]:
            if not hasattr(py3_toolchain.interpreter_version_info, attr):
                fail(_MUST_SET_TOOLCHAIN_INTERPRETER_VERSION_INFO)
        interpreter_version_info = py3_toolchain.interpreter_version_info
    else:
        fail(_MUST_SET_TOOLCHAIN_INTERPRETER_VERSION_INFO)

    return struct(
        toolchain = py3_toolchain,
        files = files,
        python = interpreter,
        interpreter_version_info = interpreter_version_info,
        runfiles_interpreter = runfiles_interpreter,
        flags = _INTERPRETER_FLAGS,
    )


def _csv(values):
    """Convert a list of strings to comma separated value string."""
    return ", ".join(sorted(values))

def _path_endswith(path, endswith):
    # Use slash to anchor each path to prevent e.g.
    # "ab/c.py".endswith("b/c.py") from incorrectly matching.
    return ("/" + path).endswith("/" + endswith)

def _determine_main(ctx):
    """Determine the main entry point .py source file.

    Args:
        ctx: The rule ctx.

    Returns:
        Artifact; the main file. If one can't be found, an error is raised.
    """
    if ctx.attr.main:
        if not ctx.attr.main.label.name.endswith(".py"):
            fail("main must end in '.py'")

        # Short circuit; if the user gave us a label, believe them.
        return ctx.file.main

    elif len(ctx.files.srcs) == 1:
        # If the user only provided one src, take that
        return ctx.files.srcs[0]

    else:
        # Legacy rule name based searching :/
        if ctx.label.name.endswith(".py"):
            fail("name must not end in '.py'")
        proposed_main = ctx.label.name + ".py"

        print(ctx.files.srcs)
        main_files = [src for src in ctx.files.srcs if _path_endswith(src.short_path, proposed_main)]

        if len(main_files) > 1:
            fail(("file name '{}' specified by 'main' attributes matches multiple files. " +
                  "Matches: {}").format(
                      proposed_main,
                      _csv([f.short_path for f in main_files]),
                  ))

        elif len(main_files) == 1:
            return main_files[0]

        else:
            fail("{} does not specify main=, and has multiple sources. Disambiguate the entrypoint".format(
                ctx.label
            ))


semantics = struct(
    interpreter_flags = _INTERPRETER_FLAGS,
    resolve_toolchain = _resolve_toolchain,
    determine_main = _determine_main,
)
