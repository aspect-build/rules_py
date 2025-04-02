"""Declare toolchains"""

load("@aspect_bazel_lib//lib:repositories.bzl", "register_tar_toolchains")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:autodetecting.bzl", _register_autodetecting_python_toolchain = "register_autodetecting_python_toolchain")
load("//py/private/toolchain:repo.bzl", "prerelease_toolchains_repo", "toolchains_repo")
load("//py/private/toolchain:tools.bzl", "TOOLCHAIN_PLATFORMS", "prebuilt_tool_repo")
load("//tools:version.bzl", "IS_PRERELEASE")

register_autodetecting_python_toolchain = _register_autodetecting_python_toolchain

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY, register = True, is_prerelease = IS_PRERELEASE):
    """Create a downloaded toolchain for every tool under every supported platform.

    Args:
        name: prefix used in created repositories
        register: whether to call the register_toolchains, should be True for WORKSPACE and False for bzlmod.
        is_prerelease: True iff there are no pre-built tool binaries for this version of rules_py
    """

    register_tar_toolchains(register = register)

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

    http_file(
        name = "rules_py_pex",
        integrity = "sha256-6X1ojdO4DBJkgXABy1k8DHCMxgdyUIpz/87LNi0kCZY=",
        urls = ["https://files.pythonhosted.org/packages/af/da/1d91d20d3e56a0f65d56106e2b56ae3e5a863e43a3f32ffbda1c3c7fa698/pex-2.33.7-py2.py3-none-any.whl"],
        downloaded_file_path = "pex-2.33.7-py2.py3-none-any.whl",
    )
