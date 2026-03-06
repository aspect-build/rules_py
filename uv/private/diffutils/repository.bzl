"""Repository rule to discover the host system's patch binary."""

def _system_diffutils_impl(repository_ctx):
    patch = repository_ctx.which("patch")
    if not patch:
        repository_ctx.file("BUILD.bazel", content = """\
# System patch binary was not found. This repo will not be functional.
# Install diffutils to enable package patching.
""")
        return

    repository_ctx.symlink(patch, "patch")
    repository_ctx.file("BUILD.bazel", content = """\
exports_files(["patch"], visibility = ["//visibility:public"])
""")

system_diffutils = repository_rule(
    implementation = _system_diffutils_impl,
    local = True,
    doc = "Discovers the host system's patch binary for use in package patching.",
)
