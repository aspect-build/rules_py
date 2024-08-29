"""Declare runtime dependencies

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive", "http_file")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//py/private/toolchain:autodetecting.bzl", _register_autodetecting_python_toolchain = "register_autodetecting_python_toolchain")
load("//py/private/toolchain:tools.bzl", "TOOLCHAIN_PLATFORMS", "prebuilt_tool_repo")
load("//py/private/toolchain:repo.bzl", "prerelease_toolchains_repo", "toolchains_repo")
load("//tools:version.bzl", "IS_PRERELEASE")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

register_autodetecting_python_toolchain = _register_autodetecting_python_toolchain

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

# WARNING: any changes in this function may be BREAKING CHANGES for users
# because we'll fetch a dependency which may be different from one that
# they were previously fetching later in their WORKSPACE setup, and now
# ours took precedence. Such breakages are challenging for users, so any
# changes in this function should be marked as BREAKING in the commit message
# and released only in semver majors.

# buildifier: disable=unnamed-macro
def rules_py_dependencies(register_toolchains = True):
    """Fetch rules_py's dependencies

    Args:
        register_toolchains: whether to also do default toolchain registration
    """

    # The minimal version of bazel_skylib we require
    http_archive(
        name = "bazel_skylib",
        sha256 = "118e313990135890ee4cc8504e32929844f9578804a1b2f571d69b1dd080cfb8",
        strip_prefix = "bazel-skylib-1.5.0",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.5.0.tar.gz",
    )

    http_archive(
        name = "aspect_bazel_lib",
        sha256 = "5371d3143307e5222e3c33a575042f93647b4e0a7d6d837f87b6b751102d27ca",
        strip_prefix = "bazel-lib-1.40.3",
        url = "https://github.com/aspect-build/bazel-lib/archive/refs/tags/v1.40.3.tar.gz",
    )

    http_archive(
        name = "rules_python",
        sha256 = "c68bdc4fbec25de5b5493b8819cfc877c4ea299c0dcb15c244c5a00208cde311",
        strip_prefix = "rules_python-0.31.0",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.31.0/rules_python-0.31.0.tar.gz",
    )

    if register_toolchains:
        rules_py_toolchains()

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY, register = True, is_prerelease = IS_PRERELEASE):
    """Create a downloaded toolchain for every tool under every supported platform.

    Args:
        name: prefix used in created repositories
        register: whether to call the register_toolchains, should be True for WORKSPACE and False for bzlmod.
        is_prerelease: True iff there are no pre-built tool binaries for this version of rules_py
    """

    # The url and digest information can be found at https://pypi.org/pypi/pex/json
    # WARNING: when updated, also update MODULE.bazel
    http_file(
        name = "pex_2_3_1",
        urls = ["https://files.pythonhosted.org/packages/e7/d0/fbda2a4d41d62d86ce53f5ae4fbaaee8c34070f75bb7ca009090510ae874/pex-2.3.1-py2.py3-none-any.whl"],
        sha256 = "64692a5bf6f298403aab930d22f0d836ae4736c5bc820e262e9092fe8c56f830",
        downloaded_file_path = "pex-2.3.1-py2.py3-none-any.whl",
    )
    
    if is_prerelease:
        prerelease_toolchains_repo(name = name)
        if register:
            native.register_toolchains(
                "@aspect_rules_py//py/private/toolchain/venv/...",
                "@aspect_rules_py//py/private/toolchain/unpack/...",
            )
    else:
        for platform in TOOLCHAIN_PLATFORMS.keys():
            prebuilt_tool_repo(name = ".".join([name, platform]), platform = platform)
        toolchains_repo(name = name, user_repository_name = name)

        if register:
            native.register_toolchains("@{}//:all".format(name))
