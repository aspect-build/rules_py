"""
Rule to expose the resolved Python toolchain interpreter as an executable.

A hermetic_launcher-based replacement for rules_python's interpreter_binary
(`@rules_python//python/bin:python`): a small native binary that resolves the
toolchain's interpreter through the Bazel runfiles mechanism at runtime and
execs it, forwarding any additional arguments. Works identically on Linux,
macOS, and Windows, both locally and under remote execution.
"""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _py_interpreter_launcher_impl(ctx):
    toolchain = ctx.toolchains[PY_TOOLCHAIN]
    runtime = toolchain.py3_runtime
    if not runtime or not runtime.interpreter:
        fail("py3_runtime must provide an in-build `interpreter` file; " +
             "system interpreters are not supported")

    executable = ctx.actions.declare_file(runtime.interpreter.basename)

    embedded_args, transformed_args = launcher.args_from_entrypoint(runtime.interpreter)
    launcher.compile_stub(
        ctx = ctx,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
        output_file = executable,
    )

    return [DefaultInfo(
        executable = executable,
        files = depset([executable]),
        runfiles = ctx.runfiles(transitive_files = depset(
            direct = [runtime.interpreter],
            transitive = [runtime.files],
        )),
    )]

py_interpreter_launcher = rule(
    doc = """\
Builds a native launcher executable for the resolved Python 3 interpreter.

The launcher locates the toolchain interpreter through the Bazel runfiles
mechanism at runtime and execs it, forwarding any extra arguments — so the
same target works locally, under remote execution, and on Windows.

Example usage in a `genrule`:

```
genrule(
    name = "run_python",
    outs = ["output.txt"],
    cmd = "$(location @aspect_rules_py//py:python) -c 'print(42)' > $@",
    tools = ["@aspect_rules_py//py:python"],
)
```

""",
    implementation = _py_interpreter_launcher_impl,
    executable = True,
    toolchains = [PY_TOOLCHAIN, launcher.finalizer_toolchain_type, launcher.template_toolchain_type],
)
