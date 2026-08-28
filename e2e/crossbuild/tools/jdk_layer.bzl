"""Re-resolves a java_runtime under the exec platform.

jpype1's CMake build runs javac/Ant on the exec platform regardless of what
CPU the compiled _jpype.so targets, but the standard `toolchains` attribute
is target-configured: a plain select() over the JDK repos would pick the
target platform's JDK and hand a Linux ELF java to a macOS host under a
cross transition. Re-resolving in the exec configuration hands back the
exec-platform JDK without hardcoding any repository label.
"""

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
            cfg = "exec",
            doc = "A java_runtime (or selecting alias), re-resolved in the exec configuration.",
            mandatory = True,
        ),
    },
    doc = "Forwards a java_runtime's files and $(JAVA)/$(JAVABASE), resolved for the exec platform.",
)
