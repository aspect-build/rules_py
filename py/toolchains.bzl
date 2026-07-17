"""Declare toolchains"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:repo.bzl", "toolchains_repo")
load("//py/private/toolchain:tools.bzl", _venv_symlink_toolchain = "venv_symlink_toolchain")

venv_symlink_toolchain = _venv_symlink_toolchain

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY):
    """Create toolchain repositories for rules_py.

    Args:
        name: prefix used in created repositories
    """
    toolchains_repo(name = name)

    http_file(
        name = "rules_py_pex_2_3_1",
        urls = ["https://files.pythonhosted.org/packages/e7/d0/fbda2a4d41d62d86ce53f5ae4fbaaee8c34070f75bb7ca009090510ae874/pex-2.3.1-py2.py3-none-any.whl"],
        sha256 = "64692a5bf6f298403aab930d22f0d836ae4736c5bc820e262e9092fe8c56f830",
        downloaded_file_path = "pex-2.3.1-py2.py3-none-any.whl",
    )
