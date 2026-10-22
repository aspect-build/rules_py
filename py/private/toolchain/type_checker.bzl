"""The `py_type_checker_toolchain` rule.

Wraps the ty binary that py_library, py_binary and py_test run when type
checking is on (see //py/private/type_check:type_check.bzl). rules_py
registers one per exec platform, downloaded by ty.bzl.
"""

PyTypeCheckerInfo = provider(
    doc = "The type checker. Carried as `ToolchainInfo.type_checker`.",
    fields = {
        "checker": "FilesToRunProvider: the ty executable (exec configuration).",
    },
)

def _py_type_checker_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        type_checker = PyTypeCheckerInfo(
            checker = ctx.attr.checker[DefaultInfo].files_to_run,
        ),
    )]

py_type_checker_toolchain = rule(
    implementation = _py_type_checker_toolchain_impl,
    doc = "Defines the ty binary for rules_py's type checking.",
    attrs = {
        "checker": attr.label(
            doc = "The ty executable.",
            mandatory = True,
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
    },
)
