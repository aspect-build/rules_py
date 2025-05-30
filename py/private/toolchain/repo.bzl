"""Create a repository to hold the toolchains

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains
"
Note that in order to resolve toolchains in the analysis phase
Bazel needs to analyze all toolchain targets that are registered.
Bazel will not need to analyze all targets referenced by toolchain.toolchain attribute.
If in order to register toolchains you need to perform complex computation in the repository,
consider splitting the repository with toolchain targets
from the repository with <LANG>_toolchain targets.
Former will be always fetched,
and the latter will only be fetched when user actually needs to build <LANG> code.
"
The "complex computation" in our case is simply downloading our pre-built rust binaries.
This guidance tells us how to avoid that: we put the toolchain targets in the alias repository
with only the toolchain attribute pointing into the platform-specific repositories.
"""

load("//py/private/toolchain:tools.bzl", "TOOLCHAIN_PLATFORMS", "TOOL_CFGS")
load("//tools:integrity.bzl", "RELEASED_BINARY_INTEGRITY")
load("//tools:version.bzl", "VERSION")

def _toolchains_repo_impl(repository_ctx):
    build_content = """# Generated by toolchains_repo.bzl
#
# These can be registered in the workspace file or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the py_register_toolchains macro
# so you don't normally need to interact with these targets.

"""
    for bin in TOOL_CFGS:
        for [platform, meta] in TOOLCHAIN_PLATFORMS.items():
            build_content += """
# Declare a toolchain Bazel will select for running {tool} on the {cfg} platform.
toolchain(
    name = "{tool}_{platform}_{cfg}_toolchain",
    {cfg}_compatible_with = {compatible_with},
    # Bazel does not follow this attribute during analysis, so the referenced repo
    # will only be fetched if this toolchain is selected.
    toolchain = "@{user_repository_name}.{platform}//:{tool}_toolchain",
    toolchain_type = "{toolchain_type}",
)

""".format(
                cfg = bin.cfg,
                tool = bin.name,
                toolchain_type = bin.toolchain_type,
                platform = platform,
                user_repository_name = repository_ctx.attr.user_repository_name,
                compatible_with = meta.compatible_with,
            )

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

toolchains_repo = repository_rule(
    _toolchains_repo_impl,
    doc = """\
    Creates a single repository with toolchain definitions for all known platforms
    that can be registered or selected.
    """,
    attrs = {
        "user_repository_name": attr.string(mandatory = True, doc = """\
        What the user chose for the base name.
        Needed since bzlmod apparent name has extra tilde segments.
        """),
    },
)

def _prerelease_toolchains_repo_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", "# No toolchains created for pre-releases")

prerelease_toolchains_repo = repository_rule(
    _prerelease_toolchains_repo_impl,
    doc = """Create a repo with an empty BUILD file, which registers no toolchains.
    This is used for pre-releases, which have no pre-built binaries, but still want to call
      register_toolchains("@this_repo//:all")
    By doing this, we can avoid those register_toolchains callsites needing to be conditional on IS_PRERELEASE
    """,
)

def _prebuilt_tool_repo_impl(rctx):
    build_content = """\
# Generated by @aspect_rules_py//py/private/toolchain:tools.bzl
load("@aspect_rules_py//py/private/toolchain:tools.bzl", "py_tool_toolchain")

package(default_visibility = ["//visibility:public"])
"""

    # For manual testing, override these environment variables
    # TODO: use rctx.getenv when available, see https://github.com/bazelbuild/bazel/pull/20944
    release_fork = "aspect-build"
    release_version = VERSION
    if "RULES_PY_RELEASE_FORK" in rctx.os.environ:
        release_fork = rctx.os.environ["RULES_PY_RELEASE_FORK"]
    if "RULES_PY_RELEASE_VERSION" in rctx.os.environ:
        release_version = rctx.os.environ["RULES_PY_RELEASE_VERSION"]

    url_template = "https://github.com/{release_fork}/rules_py/releases/download/v{release_version}/{filename}"
    if "RULES_PY_RELEASE_URL" in rctx.os.environ:
        url_template = rctx.os.environ["RULES_PY_RELEASE_URL"]

    for tool in TOOL_CFGS:
        filename = "-".join([
            tool.name,
            TOOLCHAIN_PLATFORMS[rctx.attr.platform].arch,
            TOOLCHAIN_PLATFORMS[rctx.attr.platform].vendor_os_abi,
        ])
        url = url_template.format(
            release_fork = release_fork,
            release_version = release_version,
            filename = filename,
        )
        rctx.download(
            url = url,
            sha256 = RELEASED_BINARY_INTEGRITY[filename],
            executable = True,
            output = tool.name,
        )
        build_content += """py_tool_toolchain(name = "{tool}_toolchain", bin = "{tool}", template_var = "{tool_upper}_BIN")\n""".format(
            tool = tool.name,
            tool_upper = tool.name.upper(),
        )

    rctx.file("BUILD.bazel", build_content)

prebuilt_tool_repo = repository_rule(
    doc = "Download pre-built binary tools and create concrete toolchains for them",
    implementation = _prebuilt_tool_repo_impl,
    attrs = {
        "platform": attr.string(mandatory = True, values = TOOLCHAIN_PLATFORMS.keys()),
    },
)
