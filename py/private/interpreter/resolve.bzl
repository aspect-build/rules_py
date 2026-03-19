"""Resolve a PBS interpreter label for the host platform.

Provides `resolve_host_interpreter_label()` which constructs a label pointing
to a PBS interpreter binary for the current host platform. This is used at
module-extension time (or repository-rule time) when a Python interpreter is
needed for repo-phase tooling such as sdist inspection.
"""

# The Python version to resolve. Must be configured via the
# python_interpreters extension in the root MODULE.bazel.
_PBS_PYTHON_VERSION = "3.13"

def _sanitize(s):
    """Replace characters invalid in Bazel repo names with underscores."""
    return s.replace(".", "_").replace("-", "_").replace("+", "_")

def _host_platform_triple(ctx):
    """Determine the PBS platform triple for the current host.

    Args:
        ctx: A module_ctx or repository_ctx (anything with .os.name, .os.arch,
             and .execute()).

    Returns:
        A string like "x86_64-unknown-linux-gnu" or "aarch64-apple-darwin",
        or None if the platform cannot be determined.
    """
    os = ctx.os.name
    arch = ctx.os.arch

    if arch in ("amd64", "x86_64", "x64"):
        cpu = "x86_64"
    elif arch == "aarch64":
        cpu = "aarch64"
    elif arch in ("i386", "i486", "i586", "i686", "i786", "x86"):
        cpu = "i686"
    else:
        return None

    if os.startswith("mac os"):
        return "{}-apple-darwin".format(cpu)
    elif os.startswith("linux"):
        ldd = ctx.execute(["ldd", "--version"])
        stdout = ldd.stdout.lower() if ldd.return_code == 0 else ""
        if "musl" in stdout:
            return "{}-unknown-linux-musl".format(cpu)
        return "{}-unknown-linux-gnu".format(cpu)
    elif os.startswith("windows"):
        return "{}-pc-windows-msvc".format(cpu)

    return None

def resolve_host_interpreter_label(ctx):
    """Construct a label to a PBS interpreter binary for the current host.

    Assumes that the python_interpreters extension has been configured with
    at least Python {version} in the root MODULE.bazel.

    Args:
        ctx: A module_ctx or repository_ctx.

    Returns:
        A Label pointing to the interpreter binary (e.g.
        @python_3_13_x86_64_unknown_linux_gnu//:bin/python3),
        or None if the host platform cannot be determined.
    """.format(version = _PBS_PYTHON_VERSION)

    triple = _host_platform_triple(ctx)
    if not triple:
        return None

    is_windows = triple.endswith("windows-msvc")
    binary = "python.exe" if is_windows else "bin/python3"

    repo_name = "python_{}_{}".format(
        _sanitize(_PBS_PYTHON_VERSION),
        _sanitize(triple),
    )
    return Label("@{}//:{}".format(repo_name, binary))
