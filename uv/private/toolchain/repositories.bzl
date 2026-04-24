"""Repository rules for downloading UV binaries."""

def _platform_constraints(platform):
    parts = platform.split("-")
    arch = parts[0]

    if arch == "aarch64":
        cpu = "@platforms//cpu:aarch64"
    elif arch == "x86_64":
        cpu = "@platforms//cpu:x86_64"
    elif arch == "i686":
        cpu = "@platforms//cpu:x86_32"
    else:
        cpu = "@platforms//cpu:{}".format(arch)

    if platform.endswith("apple-darwin"):
        os_constraint = "@platforms//os:macos"
    elif "windows" in platform:
        os_constraint = "@platforms//os:windows"
    else:
        os_constraint = "@platforms//os:linux"

    return "[\"{}\", \"{}\"]".format(os_constraint, cpu)

def _detect_host_platform(rctx):
    arch_map = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }

    os_name = rctx.os.name
    if os_name == "mac os x":
        os_suffix = "apple-darwin"
    elif os_name == "linux":
        os_suffix = "unknown-linux-gnu"
    elif os_name.startswith("windows"):
        os_suffix = "pc-windows-msvc"
    else:
        fail("Unsupported OS: {}".format(os_name))

    uv_arch = arch_map.get(rctx.os.arch)
    if not uv_arch:
        fail("Unsupported architecture: {}".format(rctx.os.arch))

    return "{}-{}".format(uv_arch, os_suffix)

def _uv_url(version, platform):
    ext = "zip" if platform.endswith("-windows-msvc") else "tar.gz"
    return "https://github.com/astral-sh/uv/releases/download/{}/uv-{}.{}".format(version, platform, ext)

def _uv_repository_impl(ctx):
    version = ctx.attr.version
    platform = ctx.attr.platform

    is_windows = platform.endswith("-windows-msvc")
    uv_binary = "uv.exe" if is_windows else "uv"

    # Upstream Unix tarballs have a `uv-<platform>/` top-level directory;
    # Windows zips place `uv.exe` at the root.
    ctx.download_and_extract(
        url = ctx.attr.urls if ctx.attr.urls else [_uv_url(version, platform)],
        sha256 = ctx.attr.sha256,
        canonical_id = "uv-{}-{}".format(version, platform),
        stripPrefix = "" if is_windows else "uv-{}".format(platform),
    )

    ctx.file("BUILD.bazel", '''load("@aspect_rules_py//uv/private/toolchain:types.bzl", "uv_tool_toolchain")

exports_files(["{uv_binary}"])

uv_tool_toolchain(
    name = "toolchain_impl",
    bin = "{uv_binary}",
    visibility = ["//visibility:public"],
)
'''.format(uv_binary = uv_binary))

    # Support bazel <v8.3 by returning None if repo_metadata is not defined
    if not hasattr(ctx, "repo_metadata"):
        return None

    return ctx.repo_metadata(reproducible = bool(ctx.attr.sha256))

uv_repository = repository_rule(
    implementation = _uv_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        "sha256": attr.string(),
        "urls": attr.string_list(),
    },
)

def _uv_hub_repository_impl(rctx):
    version = rctx.attr.version
    repo_prefix = rctx.attr.repo_prefix

    host_platform = _detect_host_platform(rctx)
    if host_platform not in rctx.attr.platforms:
        fail(
            "uv.toolchain(name = \"{}\", version = \"{}\") has no entry for host platform \"{}\". ".format(rctx.name, version, host_platform) +
            "Add it to `sha256s` (value may be empty for a non-reproducible fetch).",
        )

    host_uv_binary = "uv.exe" if host_platform.endswith("-windows-msvc") else "uv"
    host_repo = "{}{}".format(repo_prefix, host_platform.replace("-", "_"))

    build = '''package(default_visibility = ["//visibility:public"])

alias(
    name = "uv",
    actual = "@{host_repo}//:{host_uv_binary}",
)

'''.format(host_repo = host_repo, host_uv_binary = host_uv_binary)

    for platform in rctx.attr.platforms:
        repo = "{}{}".format(repo_prefix, platform.replace("-", "_"))
        build += '''toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {constraints},
    toolchain = "@{repo}//:toolchain_impl",
    toolchain_type = "@aspect_rules_py//uv/private/toolchain:toolchain_type",
)

'''.format(platform = platform, repo = repo, constraints = _platform_constraints(platform))

    rctx.file("BUILD.bazel", build)

    # Support bazel <v8.3 by returning None if repo_metadata is not defined
    if not hasattr(rctx, "repo_metadata"):
        return None

    return rctx.repo_metadata(reproducible = True)

uv_hub_repository = repository_rule(
    implementation = _uv_hub_repository_impl,
    configure = True,
    attrs = {
        "repo_prefix": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "platforms": attr.string_list(mandatory = True),
    },
)
