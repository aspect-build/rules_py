"""An interpreter-free Python program: an entry point plus companion modules.

Carries no launcher and resolves no toolchain, so a toolchain can depend on
one — e.g. the exec-tools toolchain's default wheel-unpack tool — and pair it
with its own interpreter, without cycling through Python toolchain resolution.
"""

PySourceToolInfo = provider(
    doc = "A toolchain-free Python program run as `<interpreter> <main> ...`.",
    fields = {
        "main": "File: the entry-point script.",
        "files": "depset[File]: `main` plus companion modules imported from its directory.",
    },
)

def _py_source_tool_impl(ctx):
    files = depset([ctx.file.main] + ctx.files.srcs)
    return [
        DefaultInfo(files = files),
        PySourceToolInfo(
            main = ctx.file.main,
            files = files,
        ),
    ]

py_source_tool = rule(
    implementation = _py_source_tool_impl,
    doc = "Bundles a Python entry-point script with its companion modules.",
    attrs = {
        "main": attr.label(
            doc = "Entry-point script.",
            allow_single_file = [".py"],
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Companion modules the entry point imports from its own directory.",
            allow_files = [".py"],
        ),
    },
    provides = [PySourceToolInfo],
)
