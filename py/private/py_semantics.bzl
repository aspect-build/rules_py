"""Functions to determine which Python toolchain to use"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
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
ERROR: The resolved Python toolchain's py3_runtime must set interpreter_version_info to \
a dict with keys "major", "minor", and "micro". Register an interpreter toolchain via \
`interpreters.toolchain()` (or another rule that sets interpreter_version_info).
"""

_MUST_PROVIDE_INTERPRETER_FILE = """
ERROR: The resolved Python toolchain's py3_runtime must provide an in-build `interpreter` \
file. rules_py requires a registered (hermetic) interpreter toolchain; system interpreters \
(a py_runtime with `interpreter_path`) are not supported.
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

    py3_runtime = toolchain_info.py3_runtime

    if py3_runtime.interpreter == None:
        fail(_MUST_PROVIDE_INTERPRETER_FILE)

    files = depset([py3_runtime.interpreter], transitive = [py3_runtime.files])
    interpreter = py3_runtime.interpreter

    for attr in ["major", "minor", "micro"]:
        if not hasattr(py3_runtime.interpreter_version_info, attr):
            fail(_MUST_SET_TOOLCHAIN_INTERPRETER_VERSION_INFO)
    interpreter_version_info = py3_runtime.interpreter_version_info

    # Read the freethreaded build setting if the consuming rule exposed
    # the attr. Freethreaded Python uses `lib/python<M>.<m>t/site-packages/`
    # instead of `lib/python<M>.<m>/site-packages/`, so assemble_venv
    # needs this to lay out the venv at the interpreter-expected path.
    freethreaded = False
    if hasattr(ctx.attr, "_freethreaded_flag"):
        freethreaded = ctx.attr._freethreaded_flag[BuildSettingInfo].value

    return struct(
        toolchain = py3_runtime,
        files = files,
        python = interpreter,
        interpreter_version_info = interpreter_version_info,
        freethreaded = freethreaded,
    )

semantics = struct(
    interpreter_flags = _INTERPRETER_FLAGS,
    resolve_toolchain = _resolve_toolchain,
)
