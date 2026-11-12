"""Declare toolchains"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:repo.bzl", "toolchains_repo")

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY):
    """Create toolchain repositories for rules_py.

    Args:
        name: prefix used in created repositories
    """
    toolchains_repo(name = name)

    http_file(
        name = "rules_py_pex_2_104_1",
        urls = ["https://files.pythonhosted.org/packages/ed/91/015d90559ac5e3e7f0ef0cd9bdb1556d2617ea6ea05c2d4fce653e624484/pex-2.104.1-py3.py312-none-any.whl"],
        sha256 = "2e4006752f61de052e45d9dad2e8e3fc59b56cc41372d53618fa412f164870f4",
        downloaded_file_path = "pex-2.104.1-py3.py312-none-any.whl",
    )
