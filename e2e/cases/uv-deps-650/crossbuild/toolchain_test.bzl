"""Analysis-time toolchain resolution test utilities.

Provides a rule that materialises the resolved exec-platform Python interpreter
path into a file, so sh_test scripts can verify which interpreter was selected
under cross-compilation (target platform ≠ exec platform).
"""

EXEC_TOOLS_TOOLCHAIN = "@rules_python//python:exec_tools_toolchain_type"

def _exec_python_path_impl(ctx):
    exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_tools.exec_runtime
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, exec_runtime.interpreter.path)
    return [DefaultInfo(files = depset([out]))]

exec_python_path = rule(
    doc = """Writes the resolved exec-platform Python interpreter path to a text file.

Used to verify that EXEC_TOOLS_TOOLCHAIN selects the exec-platform interpreter
even when the target platform differs (cross-compilation scenario). The unpack
tool (py/tools/unpack/unpack.py) runs on this interpreter, so exec-platform
resolution here is the critical invariant for hermetic cross-arch wheel installs.
""",
    implementation = _exec_python_path_impl,
    toolchains = [EXEC_TOOLS_TOOLCHAIN],
)
