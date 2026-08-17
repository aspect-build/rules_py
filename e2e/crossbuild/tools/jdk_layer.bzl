"""Re-resolves a java_runtime under the exec platform.

jpype1's CMake build runs javac/Ant on the exec platform regardless of what
CPU the compiled _jpype.so targets, but the standard `toolchains` attribute
is target-configured: a plain select() over the JDK repos would pick the
target platform's JDK and hand a Linux ELF java to a macOS host under a
cross transition. Same trick as rust_host_sysroot: re-resolve the selecting
alias under rules_py's exec_transition (--platforms := the host platform)
and forward its files + Make variables.
"""

load("@aspect_rules_py//uv/private/pep517_whl:exec_transition.bzl", "exec_transition")

def _exec_jdk_impl(ctx):
    actual = ctx.attr.actual
    if type(actual) == "list":
        actual = actual[0]
    return [
        DefaultInfo(files = actual[DefaultInfo].files),
        actual[platform_common.TemplateVariableInfo],
    ]

exec_jdk = rule(
    implementation = _exec_jdk_impl,
    attrs = {
        "actual": attr.label(
            cfg = exec_transition,
            doc = "A java_runtime (or selecting alias), re-resolved with --platforms set to the host.",
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Forwards a java_runtime's files and $(JAVA)/$(JAVABASE), resolved for the exec platform.",
)
