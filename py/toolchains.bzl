"""Declare toolchains"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:repo.bzl", "toolchains_repo")

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY, **kwargs):
    """Create toolchain repositories for rules_py.

    Args:
        name: prefix used in created repositories
        **kwargs: unused, retained for backwards compatibility
    """
    toolchains_repo(name = name, user_repository_name = name)

    http_file(
        name = "rules_py_pex",
        integrity = "sha256-6X1ojdO4DBJkgXABy1k8DHCMxgdyUIpz/87LNi0kCZY=",
        urls = ["https://files.pythonhosted.org/packages/af/da/1d91d20d3e56a0f65d56106e2b56ae3e5a863e43a3f32ffbda1c3c7fa698/pex-2.33.7-py2.py3-none-any.whl"],
        downloaded_file_path = "pex-2.33.7-py2.py3-none-any.whl",
    )
