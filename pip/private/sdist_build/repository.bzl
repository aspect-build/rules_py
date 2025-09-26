# Need to consume {src} and {deps} and produce a source build. The naive version
# of this is just `genrule()` with a `python3 -m pip wheel`. A slightly more
# involved version based on `-m build` is likely required.
#
# For the purposes of this system `uv build --wheel` is probably the way to go.
# See https://docs.astral.sh/uv/reference/cli/#uv-build for more.
#
# There's a real challenge here which is how do you get a Python which has the
# build tool(s) required. Need to look into what exactly `uv build` does and how
# that interacts with Python dependencies. My general sense is that we need to
# provide the build with an Python interpreter (venv with deps) within which
# other tools can be invoked.

def _sdist_build_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", content = """
load("@aspect_rules_py//pip/private/sdist_build:rule.bzl", "sdist_build")

sdist_build(
    name = "whl",
    src = "{src}",
    deps = {deps},
    visibility = ["//visibility:public"],
)
""".format(
    src=repository_ctx.attr.src,
    deps=repr([str(it) for it in repository_ctx.attr.deps]),
))


sdist_build = repository_rule(
    implementation = _sdist_build_impl,
    attrs = {
        "src": attr.label(),
        "deps": attr.label_list(),
    },
)
