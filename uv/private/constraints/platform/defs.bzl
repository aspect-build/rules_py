"""Platform constraint helpers and constants.

The arch and tag allowlists defined in this module are the single source of
truth used by both supported_platform() (to filter wheel tags) and the
generate_*() macros in macro.bzl (to create Bazel config_setting targets).
Keeping both sides derived from the same data makes "unsupported tag passes
the filter but has no target" bugs impossible by construction.

Constants:
    MACOS_ARCHES: Individual CPU architectures that receive their own
        config_setting targets (arm64, x86_64, i386, ppc, ppc64).
    MACOS_ARCH_GROUPS: Multi-arch group aliases defined by
        packaging.python.org platform compatibility tags. Each group
        resolves to one or more individual arches (e.g. universal2
        maps to arm64 and x86_64).
    LINUX_ARCHES: CPU architectures shared by manylinux and musllinux
        (x86_64, i686, aarch64, ppc64, ppc64le, s390x, riscv64, armv7l).
    WINDOWS_PLATFORMS: Supported Windows platform tags and their
        corresponding CPU constraints for Bazel.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

MACOS_ARCHES = [
    "arm64",
    "x86_64",
    "i386",
    "ppc",
    "ppc64",
]

MACOS_ARCH_GROUPS = {
    "universal2": ["arm64", "x86_64"],
    "universal": ["i386", "ppc", "ppc64", "x86_64"],
    "intel": ["i386", "x86_64"],
    "fat": ["i386", "ppc"],
    "fat3": ["i386", "ppc", "x86_64"],
    "fat64": ["ppc64", "x86_64"],
}

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

WINDOWS_PLATFORMS = {
    "win32": "x86_64",
    "win_amd64": "x86_64",
    "win_arm64": "aarch64",
}

def _parse_platform_arch(platform_tag):
    """Extract the architecture suffix from a platform tag.

    Tags are expected to follow the shape {prefix}_{major}_{minor}_{arch},
    for example "manylinux_2_17_x86_64".

    Args:
        platform_tag (str): A wheel platform tag.

    Returns:
        str or None: The arch portion if the tag has four components,
        otherwise None.
    """
    parts = platform_tag.split("_", 3)
    if len(parts) == 4:
        return parts[3]
    return None

def supported_platform(platform_tag):
    """Predicate that indicates whether a wheel platform tag is supported.

    Filters out wheels for platforms that are not part of the build graph:
    Android, iOS, legacy or bare linux_* tags, and architectures for which
    no config_setting targets are generated.

    Args:
        platform_tag (str): A wheel platform tag.

    Returns:
        bool: True if the platform is supported, False otherwise.
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

MAJOR_MINOR_FLAG = Label("//uv/private/constraints/platform:platform_version")

def _platform_version_at_least_impl(ctx):
    """Rule implementation adapted from rules_python's config_settings.bzl.

    Compares the current platform version (read from a build setting flag)
    against a minimum required version and emits a FeatureFlagInfo provider
    with value "true" or "false".
    """
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
