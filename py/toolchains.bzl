"""Public API for registering rules_py toolchains.

This module exposes ``rules_py_toolchains``, the entry point used by
consumers (WORKSPACE or bzlmod) to download pre-built native tools and
register the corresponding Bazel toolchains.

Known problems:
    - The PEX 2.3.1 wheel is hardcoded with a fixed URL and SHA256. There is
      no automated update rule, so security patches or bug fixes in PEX require
      a manual edit of this file.
    - The ``register`` boolean is a compatibility shim between WORKSPACE and
      bzlmod. In a pure-bzlmod world this parameter should not exist; the
      extension should simply return the toolchains to be registered.
    - The module-level docstring was historically empty (only "Declare toolchains"),
      hiding the dual release/prerelease architecture from readers.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/release:version.bzl", "IS_PRERELEASE")
load("//py/private/toolchain:autodetecting.bzl", _register_autodetecting_python_toolchain = "register_autodetecting_python_toolchain")
load("//py/private/toolchain:repo.bzl", "prebuilt_tool_repo", "prerelease_toolchains_repo", "toolchains_repo")
load("//py/private/toolchain:tools.bzl", "TOOLCHAIN_PLATFORMS", "TOOL_CFGS")

register_autodetecting_python_toolchain = _register_autodetecting_python_toolchain

DEFAULT_TOOLS_REPOSITORY = "rules_py_tools"

def rules_py_toolchains(name = DEFAULT_TOOLS_REPOSITORY, register = True, is_prerelease = IS_PRERELEASE):
    """Create downloaded toolchains for every supported platform.

    In release mode (``is_prerelease = False``) the function instantiates a
    ``prebuilt_tool_repo`` per platform listed in ``TOOLCHAIN_PLATFORMS`` and
    wraps them in a single ``toolchains_repo``. The resulting toolchains are
    registered via ``native.register_toolchains("@name//:all")`` when
    ``register`` is ``True``.

    In prerelease mode (``is_prerelease = True``) no pre-built binaries exist,
    so a ``prerelease_toolchains_repo`` is created instead and the individual
    toolchains from ``TOOL_CFGS`` are registered directly.

    Regardless of the mode, this function also declares an ``http_file`` for
    PEX 2.3.1, which is consumed elsewhere in the build to bundle Python
    entrypoints.

    Args:
        name: Prefix used for created repository names. Defaults to
            ``"rules_py_tools"``.
        register: If ``True``, call ``native.register_toolchains``. Should be
            ``True`` under WORKSPACE and ``False`` under bzlmod (where
            registration is performed by the module extension).
        is_prerelease: ``True`` when the current ``rules_py`` version has no
            published pre-built tool binaries.
    """

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
