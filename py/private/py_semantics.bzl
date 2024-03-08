"""Functions to determine which Python toolchain to use"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_INTERPRETER_FLAGS = [
    # -B     Don't write .pyc files on import. See also PYTHONDONTWRITEBYTECODE.
    "-B",
    # -I     Run Python in isolated mode. This also implies -E and -s.
    #        In isolated mode sys.path contains neither the script's directory nor the user's site-packages directory.
    #        All PYTHON* environment variables are ignored, too.
    #        Further restrictions may be imposed to prevent the user from injecting malicious code.
    "-I",
]

_MUST_SET_INTERPRETER_VERSION_FLAG = """\
ERROR: Prior to Bazel 7.x, the python interpreter version must be explicitly provided.

For example in `.bazelrc` with Bazel 6.4, add
        
    common --@aspect_rules_py//py:interpreter_version=3.9.18

Bazel 6.3 and earlier didn't handle the `common` verb for custom flags.
Repeat the flag to avoid discarding the analysis cache:

    build --@aspect_rules_py//py:interpreter_version=3.9.18
    fetch --@aspect_rules_py//py:interpreter_version=3.9.18
    query --@aspect_rules_py//py:interpreter_version=3.9.18
"""

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
    uses_interpreter_path = False

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
        uses_interpreter_path = True

    # Bazel 7 has this field on the PyRuntimeInfo
    if hasattr(py3_toolchain, "interpreter_version_info"):
        for attr in ["major", "minor", "micro"]:
            if not hasattr(py3_toolchain.interpreter_version_info, attr):
                fail(_MUST_SET_TOOLCHAIN_INTERPRETER_VERSION_INFO)
        interpreter_version_info = py3_toolchain.interpreter_version_info
    elif ctx.attr._interpreter_version_flag[BuildSettingInfo].value:
        # Back-compat for Bazel 6.
        # Same code as rules_python:
        # https://github.com/bazelbuild/rules_python/blob/76f1c76f60ccb536d3b3e2c9f023d8063f40bcd5/python/repositories.bzl#L109
        major, minor, micro = ctx.attr._interpreter_version_flag[BuildSettingInfo].value.split(".")
        interpreter_version_info = struct(
            major = major,
            minor = minor,
            micro = micro,
        )
    else:
        fail(_MUST_SET_INTERPRETER_VERSION_FLAG)

    return struct(
        toolchain = py3_toolchain,
        files = files,
        python = interpreter,
        interpreter_version_info = interpreter_version_info,
        uses_interpreter_path = uses_interpreter_path,
        flags = _INTERPRETER_FLAGS,
    )

semantics = struct(
    interpreter_flags = _INTERPRETER_FLAGS,
    resolve_toolchain = _resolve_toolchain,
)
