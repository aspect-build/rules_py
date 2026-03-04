"""
Repository rule backing sdist_build repos.

Consues a given src (.tar.gz or other artifact) and deps. Produces a
`sdist_build` rule which will eat those files and emit a built `.whl`. See the
sibling `rule.bzl` file for the implementation of `sdist_build`.
"""

# TODO: Use tar.bzl to inspect sdist contents. We can probably do a good enough
# job of detecting whether a given sdist contains C-extensions by looking at the
# inventory of the sdist using an archive extractor during this repo rule and
# applying some heuristics;
#
# - Does it contain .h .hpp .hxx .c .cxx .cpp files
# - Does it contain .pyx files
# - Does it contain .for .f90 .f95 files (fortran)
# - Does it contain .rs files
#
# Fully generally we need something like prebuilt Gazelle which we can run here
# at repo phase to try and generate a real buildfile for all the many and varied
# things which a wheel COULD need to do at install time.
#
# For now we're cheating in that there's only two build rules, and we're using
# user annotations flowed through from the user's MODULE.bazel configurations to
# provide this metadata.

def _sdist_build_impl(repository_ctx):
    """Prepares a repository for building a wheel from a source distribution (sdist).

    This rule does not perform the build itself, but generates the `BUILD.bazel`
    file that defines the necessary targets to do so.

    It creates:
    1.  A `py_venv` target named `build_venv`, which contains the build-time
        dependencies (e.g., `build`, `setuptools`, `wheel`) specified in the
        `deps` attribute.
    2.  A target (either `sdist_build` or `sdist_native_build` from `rule.bzl`)
        named `whl`. When this target is built, it executes the wheel build process
        for the given `src` sdist within the `build_venv`.

    The `is_native` attribute determines whether the build is for a pure-Python
    wheel or one that may contain C-extensions, which controls which underlying
    build rule is used.

    Args:
        repository_ctx: The repository context.
    """
    repository_ctx.file("BUILD.bazel", content = """
load("@aspect_rules_py//uv/private/sdist_build:rule.bzl", "{rule}")
load("@aspect_rules_py//py/unstable:defs.bzl", "py_venv")

py_venv(
    name = "build_venv",
    deps = {deps},
)
    
{rule}(
    name = "whl",
    src = "{src}",
    venv = ":build_venv",
    version = "{version}",
    args = [],
    visibility = ["//visibility:public"],
)
""".format(
        src = repository_ctx.attr.src,
        deps = repr([str(it) for it in repository_ctx.attr.deps]),
        rule = "sdist_native_build" if repository_ctx.attr.is_native else "sdist_build",
        version = repository_ctx.attr.version,
    ))

sdist_build = repository_rule(
    implementation = _sdist_build_impl,
    attrs = {
        "src": attr.label(),
        "deps": attr.label_list(),
        "is_native": attr.bool(),
        "version": attr.string(),
    },
)
