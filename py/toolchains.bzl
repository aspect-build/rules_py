"""Declare toolchains"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/toolchain:repo.bzl", "toolchains_repo")
load("//py/private/toolchain:ty.bzl", "DEFAULT_TY_VERSION", "TY_PLATFORMS", "TY_VERSIONS", "ty_repository")

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY, ty_version = DEFAULT_TY_VERSION):
    """Create toolchain repositories for rules_py.

    Args:
        name: prefix used in created repositories
        ty_version: version of ty backing the default type checker toolchain
    """
    if ty_version not in TY_VERSIONS:
        fail("ty version {} is not known to rules_py; choose one of: {}".format(
            ty_version,
            ", ".join(sorted(TY_VERSIONS.keys())),
        ))
    ty_repo_prefix = name + "_ty"
    for platform, triple in TY_PLATFORMS.items():
        ty_repository(
            name = "{}_{}".format(ty_repo_prefix, platform),
            version = ty_version,
            platform = triple,
            sha256 = TY_VERSIONS[ty_version][triple],
        )

    toolchains_repo(name = name, ty_repo_prefix = ty_repo_prefix)

    http_file(
        name = "rules_py_pex_2_3_1",
        urls = ["https://files.pythonhosted.org/packages/e7/d0/fbda2a4d41d62d86ce53f5ae4fbaaee8c34070f75bb7ca009090510ae874/pex-2.3.1-py2.py3-none-any.whl"],
        sha256 = "64692a5bf6f298403aab930d22f0d836ae4736c5bc820e262e9092fe8c56f830",
        downloaded_file_path = "pex-2.3.1-py2.py3-none-any.whl",
    )
