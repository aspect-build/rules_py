"""Repository rules for downloading UV binaries.

This module provides repository rules to download UV binaries from GitHub releases
for multiple platforms. UV is downloaded hermetically with optional SHA256 verification.

Example usage:
    uv_repository(
        name = "uv_0_5_27_aarch64_apple_darwin",
        version = "0.5.27",
        platform = "aarch64-apple-darwin",
        sha256 = "efe367393fc02b8e8609c38bce78d743261d7fc885e5eabfbd08ce881816aea3",
    )
"""

def _normalize_os(os_name):
    """Normalize OS names to consistent values."""
    n = os_name.lower()
    if n == "mac os x" or n == "darwin":
        return "darwin"
    if n.startswith("windows"):
        return "windows"
    return "linux"

def _normalize_arch(arch_name):
    """Normalize architecture names."""
    a = arch_name.lower()
    if a in ["x86_64", "amd64"]:
        return "x86_64"
    if a in ["aarch64", "arm64"]:
        return "aarch64"
    return a

def _detect_host_platform(rctx):
    """Detect the host platform for UV."""
    os_name = rctx.os.name
    arch = rctx.os.arch

    arch_map = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }

    if os_name == "mac os x":
        os_suffix = "apple-darwin"
    elif os_name == "linux":
        os_suffix = "unknown-linux-gnu"
    elif os_name.startswith("windows"):
        os_suffix = "pc-windows-msvc"
    else:
        fail("Unsupported OS: {}".format(os_name))

    uv_arch = arch_map.get(arch)
    if not uv_arch:
        fail("Unsupported architecture: {}".format(arch))

    return "{}-{}".format(uv_arch, os_suffix)

def _uv_url(version, platform):
    """Generate the download URL for a specific UV version and platform.
    
    Args:
        version: The UV version (e.g., "0.5.27")
        platform: The platform tuple (e.g., "aarch64-apple-darwin")
    
    Returns:
        The download URL for the UV binary
    """
    base = "https://github.com/astral-sh/uv/releases/download/{}".format(version)
    
    if platform.endswith("-windows-msvc"):
        ext = "zip"
    else:
        ext = "tar.gz"
    
    return "{}/uv-{}.{}".format(base, platform, ext)

def _uv_repository_impl(ctx):
    """Implementation of the UV repository rule."""
    version = ctx.attr.version
    platform = ctx.attr.platform
    
    url = _uv_url(version, platform)
    
    if ctx.attr.urls:
        url = ctx.attr.urls[0]
    
    kwargs = {
        "url": url,
        "canonical_id": "uv-{}-{}".format(version, platform),
    }
    
    if ctx.attr.sha256:
        kwargs["sha256"] = ctx.attr.sha256
    
    strip_prefix = "uv-{}".format(platform)
    ctx.download_and_extract(
        stripPrefix = strip_prefix,
        **kwargs
    )

    is_windows = platform.endswith("-windows-msvc")
    uv_binary = "uv.exe" if is_windows else "uv"

    ctx.file("BUILD.bazel", '''# Auto-generated BUILD file for UV {version} ({platform})

# Export the UV binary directly - this creates a target :uv that refers to the file
exports_files(["{uv_binary}"])

filegroup(
    name = "files",
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)
'''.format(
        version = version,
        platform = platform,
        uv_binary = uv_binary,
    ))

uv_repository = repository_rule(
    implementation = _uv_repository_impl,
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "The UV version to download (e.g., '0.5.27')",
        ),
        "platform": attr.string(
            mandatory = True,
            doc = "The target platform (e.g., 'x86_64-unknown-linux-gnu')",
        ),
        "sha256": attr.string(
            doc = "Optional SHA256 hash for verification. Strongly recommended for security.",
        ),
        "urls": attr.string_list(
            doc = "Optional list of mirror URLs. If provided, overrides the default GitHub URL.",
        ),
    },
    doc = """Downloads a UV binary from GitHub releases.

    This repository rule downloads UV for a specific platform from the official
    GitHub releases page and makes it available as a Bazel target.
    
    The URL is generated dynamically based on version and platform:
    https://github.com/astral-sh/uv/releases/download/{version}/uv-{platform}.tar.gz
    
    Example:
        uv_repository(
            name = "uv_0_5_27_x86_64_linux",
            version = "0.5.27",
            platform = "x86_64-unknown-linux-gnu",
            sha256 = "27261ddf7654d4f34ed4600348415e0c30de2a307cc6eff6a671a849263b2dcf",
        )
    """,
)

def _uv_host_repository_impl(rctx):
    """Implementation of the host UV repository rule."""
    platform = _detect_host_platform(rctx)
    version = rctx.attr.version
    
    url = _uv_url(version, platform)
    
    if rctx.attr.urls:
        url = rctx.attr.urls[0]
    
    kwargs = {
        "url": url,
        "canonical_id": "uv-{}-{}".format(version, platform),
    }
    
    if rctx.attr.sha256:
        kwargs["sha256"] = rctx.attr.sha256
    
    strip_prefix = "uv-{}".format(platform)
    
    rctx.download_and_extract(
        stripPrefix = strip_prefix,
        **kwargs
    )

    is_windows = platform.endswith("-windows-msvc")
    uv_binary = "uv.exe" if is_windows else "uv"

    rctx.file("BUILD.bazel", '''# Auto-generated BUILD file for UV host repository

# Export the UV binary directly - this creates a target :uv that refers to the file
exports_files(["{uv_binary}"])
'''.format(uv_binary = uv_binary))

uv_host_repository = repository_rule(
    implementation = _uv_host_repository_impl,
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "The UV version to download",
        ),
        "sha256": attr.string(
            doc = "Optional SHA256 hash for verification",
        ),
        "urls": attr.string_list(
            doc = "Optional list of mirror URLs",
        ),
    },
    doc = """Downloads UV for the host platform.

    This repository rule automatically detects the host platform and downloads
    the appropriate UV binary from GitHub releases.
    
    Example:
        uv_host_repository(
            name = "uv_toolchain",
            version = "0.5.27",
            sha256 = "auto",  # Or provide actual hash
        )
    """,
)

def _uv_platform_repository_impl(rctx):
    """Repository rule that creates a platform-independent alias to UV binary."""
    platform = _detect_host_platform(rctx)
    version = rctx.attr.version
    
    platform_repo = "uv_{}_{}".format(
        version.replace(".", "_"),
        platform.replace("-", "_"),
    )
    
    is_windows = platform.endswith("-windows-msvc")
    uv_binary = "uv.exe" if is_windows else "uv"
    
    rctx.file("BUILD.bazel", '''
# Alias to the platform-specific UV binary
alias(
    name = "uv",
    actual = "@{platform_repo}//:{uv_binary}",
    visibility = ["//visibility:public"],
)
'''.format(
        platform_repo = platform_repo,
        uv_binary = uv_binary,
    ))

uv_platform_repository = repository_rule(
    implementation = _uv_platform_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
    doc = """Creates a platform-independent alias to the UV binary.
    
    This allows using @uv//:uv from BUILD files without hardcoding
    platform-specific repository names.
    """,
)

def uv_register_toolchains(version = "0.5.27", sha256_map = None):
    """Registers UV toolchains for all supported platforms.

    This macro creates repository rules for all supported platforms and registers
    the corresponding toolchains.
    
    Args:
        version: The UV version to use (default: 0.5.27)
        sha256_map: Optional dict mapping platform -> sha256 for verification.
                   Example: {"x86_64-unknown-linux-gnu": "abc123..."}
    """
    platforms = [
        "aarch64-apple-darwin",
        "x86_64-apple-darwin",
        "aarch64-unknown-linux-gnu",
        "x86_64-unknown-linux-gnu",
        "x86_64-pc-windows-msvc",
        "aarch64-unknown-linux-musl",
        "x86_64-unknown-linux-musl",
    ]
    
    for platform in platforms:
        repo_name = "uv_{}_{}".format(
            version.replace(".", "_"),
            platform.replace("-", "_"),
        )
        sha256 = None
        if sha256_map and platform in sha256_map:
            sha256 = sha256_map[platform]
        
        uv_repository(
            name = repo_name,
            version = version,
            platform = platform,
            sha256 = sha256,
        )
    
    uv_host_repository(
        name = "aspect_rules_py_uv_toolchain",
        version = version,
        sha256 = sha256_map.get("host") if sha256_map else None,
    )
    
    uv_platform_repository(
        name = "uv",
        version = version,
    )

def uv_toolchains_register(version = "0.5.27"):
    """Deprecated: Use uv_register_toolchains instead."""
    uv_register_toolchains(version = version)
