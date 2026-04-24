"""Platform constraint generation macro for uv rules.

This module is a dependency of whl_install repository rules. Any change to
platform mappings (for example arm64 to aarch64 alignment) forces
regeneration of all wheel install repositories.

The following platform families are deliberately not generated:
- Android (android_21_arm64_v8a, android_21_armeabi_v7a, etc.)
- iOS (ios_13_0_arm64_iphoneos, ios_13_0_arm64_iphonesimulator, etc.)

The following tags are excluded because they are either Conda-specific or
otherwise invalid under the packaging.python.org specification:
- linux_armv6l, linux_armv7l, linux_x86_64
- macosx (bare, without version or arch)

See https://github.com/bazelbuild/platforms/blob/main/host/extension.bzl
for the root source of some of this mangling.

Version: 2026-03-30-v2
"""

load(":defs.bzl", "LINUX_ARCHES", "MACOS_ARCHES", "MACOS_ARCH_GROUPS", "WINDOWS_PLATFORMS", "platform_version_at_least")

# Mapping from Python packaging architecture names to the canonical CPU
# constraint values used by Bazel @platforms.
platform_repo_name_mangling = {
    it: to
    for _forms, to in [
        [["i386", "i486", "i586", "i686", "i786", "x86"], "x86_32"],
        [["amd64", "x86_64", "x64"], "x86_64"],
        [["ppc", "ppc64"], "ppc"],
        [["ppc64le"], "ppc64le"],
        [["arm", "armv7l"], "arm"],
        [["aarch64", "arm64"], "aarch64"],
        [["s390x", "s390"], "s390x"],
        [["mips64el", "mips64"], "mips64"],
        [["riscv64"], "riscv64"],
    ]
    for it in _forms
}

# buildifier: disable=unnamed-macro
def generate_macos(visibility):
    """Generate config_setting targets for macOS platform tags.

    MacOS 10 had 15 minor releases. Starting with MacOS 11 (2020) Apple
    switched to annual major versions. With MacOS 26 "Tahoe" the versioning
    scheme moved to the gregorian year. The generated matrix covers major
    versions 10 through 29 and minors 0 through 19 to remain future-proof.

    For every version and individual architecture in MACOS_ARCHES a
    config_setting is emitted. For every multi-arch group in
    MACOS_ARCH_GROUPS an alias with a select() is emitted so that the
    group resolves to the first matching member.
    """
    for major in range(10, 30):
        for minor in range(0, 20):
            major_minor = (major, minor)
            version_flag = "_is_macos_at_least_%s_%s_flat" % major_minor
            platform_version_at_least(
                name = version_flag,
                at_least = "%s.%s" % major_minor,
            )

            for arch in MACOS_ARCHES:
                native.config_setting(
                    name = "macosx_%s_%s_%s" % (major, minor, arch),
                    flag_values = {
                        version_flag: "true",
                        ":platform_libc": "libsystem",
                    },
                    constraint_values = [
                        "@platforms//os:osx",
                        "@platforms//cpu:" + platform_repo_name_mangling.get(arch, arch),
                    ],
                    visibility = visibility,
                )

            for group, members in MACOS_ARCH_GROUPS.items():
                options = [
                    ":macosx_%s_%s_%s" % (major, minor, it)
                    for it in members
                ]

                branches = {opt: opt for opt in options[:-1]}
                branches["//conditions:default"] = options[-1]

                native.alias(
                    name = "macosx_%s_%s_%s" % (major, minor, group),
                    actual = select(branches),
                    visibility = visibility,
                )

# buildifier: disable=unnamed-macro
def generate_manylinux(visibility):
    """Generate config_setting targets for manylinux platform tags.

    manylinux is defined by PEP 600. glibc 1.x was short-lived and from
    the 1990s, so the matrix only covers glibc 2.x minor versions 0
    through 50.

    Each emitted config_setting requires the glibc version flag and the
    linux OS constraint together with the mapped CPU architecture.
    """
    for major in [2]:
        for minor in range(0, 51):
            version_flag = "_is_glibc_at_least_{}_{}".format(major, minor)
            platform_version_at_least(
                name = version_flag,
                at_least = "{}.{}".format(major, minor),
            )

            for arch in LINUX_ARCHES:
                native.config_setting(
                    name = "manylinux_{}_{}_{}".format(major, minor, arch),
                    flag_values = {
                        version_flag: "true",
                        ":platform_libc": "glibc",
                    },
                    constraint_values = [
                        "@platforms//os:linux",
                        "@platforms//cpu:{}".format(platform_repo_name_mangling.get(arch, arch)),
                    ],
                    visibility = visibility,
                )

# buildifier: disable=unnamed-macro
def generate_musllinux(visibility):
    """Generate config_setting targets for musllinux platform tags.

    musl has strong backwards-compatibility promises and moves slowly,
    so it does not need as large a version matrix as glibc. The
    supported versions are explicit: 1.0, 1.1, 1.2, 2.0 and the
    hypothetical 2.1 and 2.2.

    Each config_setting requires the musl version flag and the linux OS
    constraint together with the mapped CPU architecture.
    """
    for major, minor in [
        [1, 0],
        [1, 1],
        [1, 2],
        [2, 0],
        [2, 1],
        [2, 2],
    ]:
        version_flag = "_is_musl_at_least_{}_{}".format(major, minor)
        platform_version_at_least(
            name = version_flag,
            at_least = "{}.{}".format(major, minor),
        )

        for arch in LINUX_ARCHES:
            native.config_setting(
                name = "musllinux_{}_{}_{}".format(major, minor, arch),
                flag_values = {
                    version_flag: "true",
                    ":platform_libc": "musl",
                },
                constraint_values = [
                    "@platforms//os:linux",
                    "@platforms//cpu:{}".format(platform_repo_name_mangling.get(arch, arch)),
                ],
                visibility = visibility,
            )

# buildifier: disable=unnamed-macro
def generate_windows(visibility):
    """Generate config_setting targets for Windows platform tags.

    Emits one config_setting per entry in WINDOWS_PLATFORMS. Every
    target requires the msvc libc flag and the windows OS constraint
    together with the CPU value defined in the WINDOWS_PLATFORMS map.
    """
    for name, cpu in WINDOWS_PLATFORMS.items():
        native.config_setting(
            name = name,
            flag_values = {
                ":platform_libc": "msvc",
            },
            constraint_values = [
                "@platforms//os:windows",
                "@platforms//cpu:" + cpu,
            ],
            visibility = visibility,
        )

# buildifier: disable=unnamed-macro
def generate(visibility):
    """Emit platform constraint targets for all supported operating systems.

    Invokes the macOS, manylinux, musllinux and Windows generators with
    the provided visibility.
    """
    generate_macos(visibility = visibility)
    generate_manylinux(visibility = visibility)
    generate_musllinux(visibility = visibility)
    generate_windows(visibility = visibility)
