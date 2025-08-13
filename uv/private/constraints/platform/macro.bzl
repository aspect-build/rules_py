"""

"""

load("@aspect_rules_py_uv_host//:defs.bzl", "CURRENT_PLATFORM")
load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "generate_gte_ladder")

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

## These are long obsolete manylinux wheel formats we're ignoring.
## Hopefully we can just ignore that....
# manylinux1_i686
# manylinux1_x86_64
# manylinux2010_i686
# manylinux2010_x86_64
# manylinux2014_aarch64
# manylinux2014_armv7l
# manylinux2014_i686
# manylinux2014_ppc64
# manylinux2014_ppc64le
# manylinux2014_s390x
# manylinux2014_x86_64

## These seem wrong?
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
def generate_macos():
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

    stages = []

    # MacOS 10 ran for 15 minor releases
    # Since then with MacOS 11 (2020) Apple's gone to an annual major version
    # With MacOS 26 "Tahoe" they've gone to using the gregorian year for the version
    # Go a bit out into the future there
    for major in range(10, 30):
        for minor in range(0, 20):
            name = "is_macosx_{}_{}".format(major, minor)
            native.constraint_value(
                name = name,
                constraint_setting = ":platform",
            )
            stages.append(struct(name = name[3:], condition = name))

            for arch in arches:
                selects.config_setting_group(
                    name = "macosx_{}_{}_{}".format(major, minor, arch),
                    match_all = [
                        ":macosx_{}_{}".format(major, minor),
                        "@platforms//os:osx",
                        "@platforms//cpu:{}".format(platform_repo_name_mangling.get(arch, arch)),
                    ],
                )

            for group, members in arch_groups.items():
                selects.config_setting_group(
                    name = "macosx_{}_{}_{}".format(major, minor, group),
                    match_any = [
                        ":macosx_{}_{}_{}".format(major, minor, it)
                        for it in members
                    ],
                )

    generate_gte_ladder(stages)

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate_manylinux():
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

    stages = []

    # glibc 1.X ran for not that long and was in the 90s
    for major in [2]:
        for minor in range(0, 51):
            name = "is_manylinux_{}_{}".format(major, minor)
            native.constraint_value(
                name = name,
                constraint_setting = ":platform",
            )
            stages.append(struct(name = name[3:], condition = name))

            for arch in arches:
                selects.config_setting_group(
                    name = "manylinux_{}_{}_{}".format(major, minor, arch),
                    match_all = [
                        ":manylinux_{}_{}".format(major, minor),
                        "@platforms//os:linux",
                        "@platforms//cpu:{}".format(platform_repo_name_mangling.get(arch, arch)),
                    ],
                )

    generate_gte_ladder(stages)

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate_musllinux():
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

    stages = []

    # TODO: musl moves super slow and has strong back compat promises, doesn't clearly need a huge matrix?
    for major, minor in [
        [1, 0],
        [1, 1],
        [1, 2],
        [2, 0],
        [2, 1],  # Hypothetical
        [2, 2],  # Hypothetical
    ]:
        name = "is_musllinux_{}_{}".format(major, minor)
        native.constraint_value(
            name = name,
            constraint_setting = ":platform",
        )
        stages.append(struct(name = name[3:], condition = name))

        for arch in arches:
            selects.config_setting_group(
                name = "musllinux_{}_{}_{}".format(major, minor, arch),
                match_all = [
                    ":musllinux_{}_{}".format(major, minor),
                    "@platforms//os:linux",
                    "@platforms//cpu:{}".format(platform_repo_name_mangling.get(arch, arch)),
                ],
            )

    generate_gte_ladder(stages)

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

# win32
# win64
# win_amd64
# win_arm64
# win_ia64

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate():
    # FIXME: Is there a better/worse way to do this?
    selects.config_setting_group(
        name = "any",
        match_all = [
            "//conditions:default",
        ],
    )

    native.constraint_setting(
        name = "platform",
        default_constraint_value = CURRENT_PLATFORM,
    )

    generate_macos()
    generate_manylinux()
    generate_musllinux()

    # FIXME: Is this right?
    native.alias(
        name = "linux_armv7l",
        actual = "manylinux_2_17_armv7l",
    )

    # https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/#manylinux
    selects.config_setting_group(
        name = "manylinux1",
        match_any = [
            ":manylinux_2_5_x86_64",
            ":manylinux_2_5_i686",
        ],
    )

    selects.config_setting_group(
        name = "manylinux2010",
        match_any = [
            ":manylinux_2_12_x86_64",
            ":manylinux_2_12_i686",
        ],
    )

    selects.config_setting_group(
        name = "manylinux2014",
        match_any = [
            ":manylinux_2_17_x86_64",
            ":manylinux_2_17_i686",
            ":manylinux_2_17_aarch64",
            ":manylinux_2_17_armv7l",
            ":manylinux_2_17_ppc64",
            ":manylinux_2_17_ppc64le",
            ":manylinux_2_17_s390x",
        ],
    )

    native.constraint_value(
        name = "is_win32",
        constraint_setting = ":platform",
    )
    native.alias(
        name = "win32",
        actual = ":is_win32",
    )

    native.constraint_value(
        name = "is_win64",
        constraint_setting = ":platform",
    )
    native.alias(
        name = "win64",
        actual = ":is_win64",
    )

    # FIXME: These should be and?
    native.constraint_value(
        name = "is_win_amd64",
        constraint_setting = ":platform",
    )
    native.alias(
        name = "win_amd64",
        actual = ":is_win_amd64",
    )

    native.constraint_value(
        name = "is_win_arm64",
        constraint_setting = ":platform",
    )
    native.alias(
        name = "win_arm64",
        actual = ":is_win_arm64",
    )

    native.constraint_value(
        name = "is_win_ia64",
        constraint_setting = ":platform",
    )
    native.alias(
        name = "win_ia64",
        actual = ":is_win_ia64",
    )
