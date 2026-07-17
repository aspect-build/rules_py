"""Rule to expose the resolved Python toolchain as Make variables.

Provides `$(PYTHON3)` and `$(PYTHON3_ROOTPATH)` for use in `genrule`,
`bazel_env`, and other rules that support Make variable expansion.
"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _current_py_toolchain_impl(ctx):
    direct = []
    transitive = []
    vars = {}

    toolchain = ctx.toolchains[PY_TOOLCHAIN]
    if toolchain.py3_runtime:
        if not toolchain.py3_runtime.interpreter:
            fail("py3_runtime must provide an in-build `interpreter` file; " +
                 "system interpreters are not supported")
        direct.append(toolchain.py3_runtime.interpreter)
        transitive.append(toolchain.py3_runtime.files)
        vars["PYTHON3"] = toolchain.py3_runtime.interpreter.path
        vars["PYTHON3_ROOTPATH"] = toolchain.py3_runtime.interpreter.short_path

    files = depset(direct, transitive = transitive)
    return [
        platform_common.TemplateVariableInfo(vars),
        DefaultInfo(
            runfiles = ctx.runfiles(transitive_files = files),
            files = files,
        ),
    ]

current_py_toolchain = rule(
    doc = """\
Exposes the resolved Python 3 toolchain as Make variables.

After toolchain resolution, this rule provides `$(PYTHON3)` and
`$(PYTHON3_ROOTPATH)` for Make variable expansion in rules like
`genrule` and `bazel_env`.

An instance is automatically available at
`@python_interpreters//:current_py_toolchain` when using the
`python_interpreters` module extension.

Example usage with `genrule`:

```starlark
genrule(
    name = "run_python",
    outs = ["output.txt"],
    cmd = "$(PYTHON3) -c 'print(42)' > $@",
    toolchains = ["@python_interpreters//:current_py_toolchain"],
)
```

Example usage with `bazel_env`:

```starlark
bazel_env(
    name = "bazel_env",
    toolchains = {
        "python": "@python_interpreters//:current_py_toolchain",
    },
    tools = {
        "python": "$(PYTHON3)",
    },
)
```
""",
    implementation = _current_py_toolchain_impl,
    toolchains = [PY_TOOLCHAIN],
)
