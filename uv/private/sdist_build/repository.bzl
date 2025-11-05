"""
Repository rule backing sdist_build repos.

Consues a given src (.tar.gz or other artifact) and deps. Produces a
`sdist_build` rule which will eat those files and emit a built `.whl`. See the
sibling `rule.bzl` file for the implementation of `sdist_build`.
"""

def _sdist_build_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", content = """
load("@aspect_rules_py//uv/private/sdist_build:rule.bzl", "sdist_build")

sdist_build(
    name = "whl",
    src = "{src}",
    deps = {deps},
    visibility = ["//visibility:public"],
)
""".format(
        src = repository_ctx.attr.src,
        deps = repr([str(it) for it in repository_ctx.attr.deps]),
    ))

sdist_build = repository_rule(
    implementation = _sdist_build_impl,
    attrs = {
        "src": attr.label(),
        "deps": attr.label_list(),
    },
)
