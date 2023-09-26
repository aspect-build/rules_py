load(":utils.bzl", "PY_TOOLCHAIN")

def _current_py_toolchain_impl(ctx):
    toolchain = ctx.toolchains[PY_TOOLCHAIN]

    direct = []
    transitive = []
    vars = {}
    original_executable = None
    executable = None

    if toolchain.py2_runtime and toolchain.py2_runtime.interpreter:
        direct.append(toolchain.py2_runtime.interpreter)
        transitive.append(toolchain.py2_runtime.files)
        vars["PYTHON2"] = toolchain.py2_runtime.interpreter.path
        original_executable = toolchain.py2_runtime.interpreter

    if toolchain.py3_runtime and toolchain.py3_runtime.interpreter:
        direct.append(toolchain.py3_runtime.interpreter)
        transitive.append(toolchain.py3_runtime.files)
        vars["PYTHON3"] = toolchain.py3_runtime.interpreter.path
        original_executable = toolchain.py3_runtime.interpreter

    if original_executable:
        executable = ctx.actions.declare_file(original_executable.basename)
        ctx.actions.symlink(
            output = executable,
            target_file = original_executable,
            is_executable = True,
        )
        direct.append(executable)

    files = depset(direct, transitive = transitive)
    return [
        toolchain,
        platform_common.TemplateVariableInfo(vars),
        DefaultInfo(
            runfiles = ctx.runfiles(transitive_files = files),
            files = files,
            executable = executable
        ),
    ]

current_py_toolchain = rule(
    implementation = _current_py_toolchain_impl,
    toolchains = [
        PY_TOOLCHAIN
    ],
)