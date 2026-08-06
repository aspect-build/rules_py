"""Exposes a vendored Apache Ant install's bin/ dir as a Make variable.

Ant is plain Java bytecode plus shell/bat launcher scripts — architecture
independent, so unlike the Rust toolchain there's no host/target split to
worry about: jpype1's CMake build only ever runs Ant to build a JAR (always
a host-executed step, regardless of what CPU the compiled .so targets).
"""

def _ant_home_impl(ctx):
    ant_bin = ctx.file.ant_bin
    return [
        DefaultInfo(files = ctx.attr.all_files[DefaultInfo].files),
        platform_common.TemplateVariableInfo({
            "ANT_HOME": ant_bin.dirname.rsplit("/", 1)[0],
            "ANT_BIN_DIR": ant_bin.dirname,
        }),
    ]

ant_home = rule(
    implementation = _ant_home_impl,
    attrs = {
        "all_files": attr.label(
            doc = "filegroup covering the whole extracted Ant distribution.",
            mandatory = True,
        ),
        "ant_bin": attr.label(
            allow_single_file = True,
            doc = "The `bin/ant` launcher script.",
            mandatory = True,
        ),
    },
    doc = "Exposes $(ANT_HOME) / $(ANT_BIN_DIR) for a vendored Ant distribution.",
)
