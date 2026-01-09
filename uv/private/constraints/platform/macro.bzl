"""

"""

load(":defs.bzl", "platform_version_at_least")

## These are defined but we're ignoring them for now.
# android_21_arm64_v8a
# android_21_armeabi_v7a
# android_21_x86_64
# android_24_arm64_v8a
# android_24_x86_64
# android_26_arm64_v8a
# android_26_x86_64
# android_28_arm64_v8a
# android_33_arm64_v8a
# ios_13_0_arm64_iphoneos
# ios_13_0_arm64_iphonesimulator
# ios_13_0_x86_64_iphonesimulator

## These seem wrong and/or are defined by Conda not packaging
# linux_armv6l
# linux_armv7l
# linux_x86_64
# macosx

# See
# https://github.com/bazelbuild/platforms/blob/main/host/extension.bzl#L1-L20
# for the root source of some of this mangling....
platform_repo_name_mangling = {
    it: to
    for _forms, to in [
        [["i386", "i486", "i586", "i686", "i786", "x86"], "x86_32"],
        [["amd64", "x86_64", "x64"], "x86_64"],
        [["ppc", "ppc64"], "ppc"],
        [["ppc64le"], "ppc64le"],
        [["arm", "armv7l"], "arm"],
        [["aarch64"], "aarch64"],
        [["s390x", "s390"], "s390x"],
        [["mips64el", "mips64"], "mips64"],
        [["riscv64"], "riscv64"],
    ]
    for it in _forms
}

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate_macos(visibility):
    """
    Deliberately generate an overfull matrix of possible MacOS versions and arches.
    """

    # https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/#macos
    arch_groups = {
        "universal2": ["arm64", "x86_64"],
        "universal": ["i386", "ppc", "ppc64", "x86_64"],
        "intel": ["i386", "x86_64"],
        "fat": ["i386", "ppc"],
        "fat3": ["i386", "ppc", "x86_64"],
        "fat64": ["ppc64", "x86_64"],
    }
    arches = [
        "arm64",
        "x86_64",
        "i386",
        "ppc",
        "ppc64",
    ]

    # MacOS 10 ran for 15 minor releases
    # Since then with MacOS 11 (2020) Apple's gone to an annual major version
    # With MacOS 26 "Tahoe" they've gone to using the gregorian year for the version
    # Go a bit out into the future there
    for major in range(10, 30):
        for minor in range(0, 20):
            major_minor = (major, minor)
            version_flag = "_is_macos_at_least_%s_%s_flat" % major_minor
            platform_version_at_least(
                name = version_flag,
                at_least = "%s.%s" % major_minor,
            )

            for arch in arches:
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

            for group, members in arch_groups.items():
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
# buildifier: disable=function-docstring
def generate_manylinux(visibility):
    # https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/#manylinux

    arches = [
        "x86_64",
        "i686",
        "aarch64",
        "ppc64",
        "ppc64le",
        "s390x",
        "riscv64",
        "armv7l",
    ]

    # glibc 1.X ran for not that long and was in the 90s
    for major in [2]:
        for minor in range(0, 51):
            version_flag = "_is_glibc_at_least_{}_{}".format(major, minor)
            platform_version_at_least(
                name = version_flag,
                at_least = "{}.{}".format(major, minor),
            )

            for arch in arches:
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
# buildifier: disable=function-docstring
def generate_musllinux(visibility):
    # musllinux_1_0_aarch64
    # musllinux_1_0_armv7l
    # musllinux_1_0_i686
    # musllinux_1_0_x86_64
    # musllinux_1_1_aarch64
    # musllinux_1_1_armv7l
    # musllinux_1_1_i686
    # musllinux_1_1_ppc64le
    # musllinux_1_1_riscv64
    # musllinux_1_1_s390x
    # musllinux_1_1_x86_64
    # musllinux_1_2_aarch64
    # musllinux_1_2_armv7l
    # musllinux_1_2_i686
    # musllinux_1_2_ppc64le
    # musllinux_1_2_riscv64
    # musllinux_1_2_s390x
    # musllinux_1_2_x86_64
    # musllinux_2_0_aarch64
    # musllinux_2_0_x86_64

    arches = [
        "x86_64",
        "i686",
        "aarch64",
        "ppc64",
        "ppc64le",
        "s390x",
        "riscv64",
        "armv7l",
    ]

    # TODO: musl moves super slow and has strong back compat promises, doesn't clearly need a huge matrix?
    for major, minor in [
        [1, 0],
        [1, 1],
        [1, 2],
        [2, 0],
        [2, 1],  # Hypothetical
        [2, 2],  # Hypothetical
    ]:
        version_flag = "_is_musl_at_least_{}_{}".format(major, minor)
        platform_version_at_least(
            name = version_flag,
            at_least = "{}.{}".format(major, minor),
        )

        for arch in arches:
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
# buildifier: disable=function-docstring
def generate_windows(visibility):
    native.config_setting(
        name = "win32",
        flag_values = {
            ":platform_libc": "msvc",
        },
        constraint_values = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        visibility = visibility,
    )
    native.config_setting(
        name = "win_amd64",
        flag_values = {
            ":platform_libc": "msvc",
        },
        constraint_values = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        visibility = visibility,
    )
    native.config_setting(
        name = "win_arm64",
        flag_values = {
            ":platform_libc": "msvc",
        },
        constraint_values = [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
        visibility = visibility,
    )

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate(visibility):
    generate_macos(visibility = visibility)
    generate_manylinux(visibility = visibility)
    generate_musllinux(visibility = visibility)
    generate_windows(visibility = visibility)
