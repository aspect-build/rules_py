"""Declare toolchains"""

load("@aspect_bazel_lib//lib:repositories.bzl", "register_tar_toolchains")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:autodetecting.bzl", _register_autodetecting_python_toolchain = "register_autodetecting_python_toolchain")
load("//py/private/toolchain:repo.bzl", "prebuilt_tool_repo", "prerelease_toolchains_repo", "toolchains_repo")
load("//py/private/toolchain:tools.bzl", "TOOLCHAIN_PLATFORMS", "TOOL_CFGS")
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
            for tool in TOOL_CFGS:
                native.register_toolchains(tool.toolchain)
    else:
        for platform in TOOLCHAIN_PLATFORMS.keys():
            prebuilt_tool_repo(name = ".".join([name, platform]), platform = platform)
        toolchains_repo(name = name, user_repository_name = name)

        if register:
            native.register_toolchains("@{}//:all".format(name))

    http_file(
        name = "rules_py_pex_2_3_1",
        urls = ["https://files.pythonhosted.org/packages/e7/d0/fbda2a4d41d62d86ce53f5ae4fbaaee8c34070f75bb7ca009090510ae874/pex-2.3.1-py2.py3-none-any.whl"],
        sha256 = "64692a5bf6f298403aab930d22f0d836ae4736c5bc820e262e9092fe8c56f830",
        downloaded_file_path = "pex-2.3.1-py2.py3-none-any.whl",
    )
