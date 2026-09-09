"""The bytecode compiler toolchain: one per Python feature version and exec platform."""

load("//py/private/interpreter:runtime.bzl", "PyRuntimeInfo")

PycCompilerInfo = provider(
    doc = "Private: how to invoke the first-party bytecode compiler.",
    fields = {
        "arguments": "list — leading arguments before the compiler's own.",
        "executable": "File or FilesToRunProvider — what the action runs.",
        "runtime": "PyRuntimeInfo of the compiling interpreter, or None for a self-contained tool.",
        "supports_workers": "bool — whether the tool speaks Bazel's JSON worker protocol.",
        "tools": "depset[File] — the compiler closure; Bazel keys worker reuse on it.",
    },
)

def runtime_compiler(runtime, script):
    """The reference compiler `script` run by a file-based `runtime`."""
    return PycCompilerInfo(
        arguments = ["-S", "-s", "-B", script],
        executable = runtime.interpreter,
        runtime = runtime,
        supports_workers = True,
        tools = depset([runtime.interpreter, script], transitive = [runtime.files]),
    )

def _py_pyc_compiler_toolchain_impl(ctx):
    if bool(ctx.attr.runtime) == bool(ctx.attr.tool):
        fail("exactly one of runtime or tool must be set")

    if ctx.attr.tool:
        compiler = PycCompilerInfo(
            arguments = [],
            executable = ctx.attr.tool[DefaultInfo].files_to_run,
            runtime = None,
            supports_workers = False,
            tools = depset(),
        )
    else:
        runtime = ctx.attr.runtime[PyRuntimeInfo]
        if runtime.interpreter == None:
            fail("runtime must provide an in-build interpreter file")
        compiler = runtime_compiler(runtime, ctx.file._script)
    return [platform_common.ToolchainInfo(pyc_compiler = compiler)]

py_pyc_compiler_toolchain = rule(
    doc = """Declares a bytecode compiler for `pyc_compiler_toolchain_type`.

Exactly one of `runtime` or `tool` is required. A `tool` must implement the
`@ARGFILE` interface of `py/private/pyc_compile.py` and be registered with the
same version gating as the interpreter it stands in for. Compile actions are
path-mapped, so a `tool` must write only to the paths it is given and embed
only the `DFILE` argument, never an input or output path, in its bytecode.""",
    implementation = _py_pyc_compiler_toolchain_impl,
    attrs = {
        "runtime": attr.label(
            doc = "File-based Python runtime that executes the reference compiler.",
            providers = [PyRuntimeInfo],
        ),
        "tool": attr.label(
            doc = "Self-contained compiler executable.",
            executable = True,
            cfg = "exec",
        ),
        "_script": attr.label(default = "//py/private:pyc_compile.py", allow_single_file = True),
    },
)
