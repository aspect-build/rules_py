"""
Helpers & constants.

Platform arch/tag allowlists defined here are the single source of truth used
by both supported_platform() (to filter wheel tags) and the generate_*()
macros in macro.bzl (to create Bazel config_setting targets). Keeping both
sides derived from the same data makes "unsupported tag passes the filter but
has no target" bugs impossible by construction.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

# macOS individual CPU architectures that get their own config_setting targets.
MACOS_ARCHES = [
    "arm64",
    "x86_64",
    "i386",
    "ppc",
    "ppc64",
]

# macOS multi-arch group aliases (each resolves to one of the individual arches).
# https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/#macos
MACOS_ARCH_GROUPS = {
    "universal2": ["arm64", "x86_64"],
    "universal": ["i386", "ppc", "ppc64", "x86_64"],
    "intel": ["i386", "x86_64"],
    "fat": ["i386", "ppc"],
    "fat3": ["i386", "ppc", "x86_64"],
    "fat64": ["ppc64", "x86_64"],
}

# CPU architectures shared by manylinux and musllinux.
LINUX_ARCHES = [
    "x86_64",
    "i686",
    "aarch64",
    "ppc64",
    "ppc64le",
    "s390x",
    "riscv64",
    "armv7l",
]

# Supported Windows platform tags and their CPU constraints.
WINDOWS_PLATFORMS = {
    "win32": "x86_64",
    "win_amd64": "x86_64",
    "win_arm64": "aarch64",
}

def _parse_platform_arch(platform_tag):
    """Extract the arch suffix from a {prefix}_{major}_{minor}_{arch} tag.

    Args:
        platform_tag (str): A platform tag like "manylinux_2_17_x86_64".

    Returns:
        str or None; the arch portion, or None if the tag doesn't have the
        expected structure.
    """
    parts = platform_tag.split("_", 3)
    if len(parts) == 4:
        return parts[3]
    return None

def supported_platform(platform_tag):
    """Predicate.

    Indicate whether the current `pip` implementation supports the platform
    represented by a given wheel platform tag. Allows for filtering out of
    wheels for currently unsupported platforms, being:

    - Android
    - iOS
    - The legacy/undefined linux_* platforms
    - Architectures we don't generate config_setting targets for

    Args:
        platform_tag (str): A wheel platform tag

    Returns:
        bool; whether the platform is supported or not.

    """
    if platform_tag == "any":
        return True

    if platform_tag.startswith("macosx_"):
        arch = _parse_platform_arch(platform_tag)
        return arch != None and (arch in MACOS_ARCHES or arch in MACOS_ARCH_GROUPS)

    if platform_tag.startswith("manylinux_") or platform_tag.startswith("musllinux_"):
        arch = _parse_platform_arch(platform_tag)
        return arch != None and arch in LINUX_ARCHES

    return platform_tag in WINDOWS_PLATFORMS

# Adapted from rules_python's config_settings.bzl
MAJOR_MINOR_FLAG = Label("//uv/private/constraints/platform:platform_version")

def _platform_version_at_least_impl(ctx):
    flag_value = ctx.attr._major_minor[BuildSettingInfo].value

    current = tuple([
        int(x)
        for x in flag_value.split(".")
    ])
    at_least = tuple([int(x) for x in ctx.attr.at_least.split(".")])

    value = "true" if current >= at_least else "false"
    return [config_common.FeatureFlagInfo(value = value)]

platform_version_at_least = rule(
    implementation = _platform_version_at_least_impl,
    attrs = {
        "at_least": attr.string(mandatory = True),
        "_major_minor": attr.label(default = MAJOR_MINOR_FLAG),
    },
)
