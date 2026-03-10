load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "LINUX_ARCHES", "MACOS_ARCHES", "MACOS_ARCH_GROUPS", "WINDOWS_PLATFORMS", "supported_platform")

# -- supported_platform: accepted tags -----------------------------------------

def _any_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, supported_platform("any"))
    return unittest.end(env)

any_test = unittest.make(_any_test_impl)

def _macos_arches_test_impl(ctx):
    env = unittest.begin(ctx)
    for arch in MACOS_ARCHES:
        asserts.true(env, supported_platform("macosx_11_0_%s" % arch), "macosx arch %s should be supported" % arch)
    for group in MACOS_ARCH_GROUPS:
        asserts.true(env, supported_platform("macosx_10_15_%s" % group), "macosx group %s should be supported" % group)
    return unittest.end(env)

macos_arches_test = unittest.make(_macos_arches_test_impl)

def _manylinux_arches_test_impl(ctx):
    env = unittest.begin(ctx)
    for arch in LINUX_ARCHES:
        asserts.true(env, supported_platform("manylinux_2_17_%s" % arch), "manylinux arch %s should be supported" % arch)
    return unittest.end(env)

manylinux_arches_test = unittest.make(_manylinux_arches_test_impl)

def _musllinux_arches_test_impl(ctx):
    env = unittest.begin(ctx)
    for arch in LINUX_ARCHES:
        asserts.true(env, supported_platform("musllinux_1_1_%s" % arch), "musllinux arch %s should be supported" % arch)
    return unittest.end(env)

musllinux_arches_test = unittest.make(_musllinux_arches_test_impl)

def _windows_platforms_test_impl(ctx):
    env = unittest.begin(ctx)
    for tag in WINDOWS_PLATFORMS:
        asserts.true(env, supported_platform(tag), "windows platform %s should be supported" % tag)
    return unittest.end(env)

windows_platforms_test = unittest.make(_windows_platforms_test_impl)

# -- supported_platform: rejected tags -----------------------------------------

def _reject_win_ia64_test_impl(ctx):
    """Regression: win_ia64 has no config_setting target and must be rejected."""
    env = unittest.begin(ctx)
    asserts.false(env, supported_platform("win_ia64"), "win_ia64 must not be supported")
    return unittest.end(env)

reject_win_ia64_test = unittest.make(_reject_win_ia64_test_impl)

def _reject_unsupported_arches_test_impl(ctx):
    env = unittest.begin(ctx)

    # Unknown linux arch
    asserts.false(env, supported_platform("manylinux_2_17_sparc64"), "sparc64 is not a supported linux arch")
    asserts.false(env, supported_platform("musllinux_1_1_mips"), "mips is not a supported linux arch")

    # Unknown macOS arch
    asserts.false(env, supported_platform("macosx_11_0_mips"), "mips is not a supported macOS arch")

    # Unsupported OS families
    asserts.false(env, supported_platform("android_21_arm64_v8a"), "android should not be supported")
    asserts.false(env, supported_platform("ios_13_0_arm64_iphoneos"), "ios should not be supported")
    asserts.false(env, supported_platform("linux_x86_64"), "bare linux_ should not be supported")

    return unittest.end(env)

reject_unsupported_arches_test = unittest.make(_reject_unsupported_arches_test_impl)

def _reject_malformed_tags_test_impl(ctx):
    env = unittest.begin(ctx)

    # Too few components
    asserts.false(env, supported_platform("macosx_11"), "truncated macosx tag should be rejected")
    asserts.false(env, supported_platform("manylinux_2"), "truncated manylinux tag should be rejected")
    asserts.false(env, supported_platform("musllinux_1"), "truncated musllinux tag should be rejected")

    return unittest.end(env)

reject_malformed_tags_test = unittest.make(_reject_malformed_tags_test_impl)

# -- Real-world wheel platform tags from the uv cache -------------------------

def _real_world_tags_test_impl(ctx):
    """Verify supported_platform handles real wheel platform tags from the wild."""
    env = unittest.begin(ctx)

    # Accepted: real tags seen in ~/.cache/uv/wheels-v6/pypi/
    for tag in [
        "any",
        "macosx_10_9_x86_64",
        "macosx_14_0_arm64",
        "macosx_10_15_universal2",
        "macosx_10_9_intel",
        "manylinux_2_17_x86_64",
        "manylinux_2_17_aarch64",
        "manylinux_2_17_i686",
        "manylinux_2_31_x86_64",
        "manylinux_2_27_aarch64",
        "musllinux_1_1_x86_64",
        "musllinux_1_2_aarch64",
        "win32",
        "win_amd64",
        "win_arm64",
    ]:
        asserts.true(env, supported_platform(tag), "real-world tag %s should be supported" % tag)

    # Rejected: tags seen in the wild that we intentionally do not support
    for tag in [
        "win_ia64",
        "linux_armv7l",
        "linux_armv6l",
        "android_21_arm64_v8a",
    ]:
        asserts.false(env, supported_platform(tag), "tag %s should be rejected" % tag)

    return unittest.end(env)

real_world_tags_test = unittest.make(_real_world_tags_test_impl)

# -- Suite ---------------------------------------------------------------------

def platform_suite():
    unittest.suite(
        "platform_tests",
        any_test,
        macos_arches_test,
        manylinux_arches_test,
        musllinux_arches_test,
        windows_platforms_test,
        reject_win_ia64_test,
        reject_unsupported_arches_test,
        reject_malformed_tags_test,
        real_world_tags_test,
    )
