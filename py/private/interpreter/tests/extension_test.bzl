"""Tests for extension.bzl mode resolution and SHA256SUMS parsing."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:extension.bzl", "extension_testlib")
load("//py/private/interpreter:versions.bzl", "PLATFORMS")

_RELEASE_DATE = "20260303"

# A synthetic SHA256SUMS excerpt: two 3.13 patches, sibling build
# configurations, a free-threaded archive, and a second minor version.
_SHA256SUMS = "\n".join([
    "aaa1  cpython-3.13.1+20260303-x86_64-unknown-linux-gnu-install_only.tar.gz",
    "bbb2  cpython-3.13.2+20260303-x86_64-unknown-linux-gnu-install_only.tar.gz",
    "ccc3  cpython-3.13.2+20260303-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "ddd4  cpython-3.13.2+20260303-x86_64-unknown-linux-gnu-debug-full.tar.zst",
    "eee5  cpython-3.13.2+20260303-x86_64-unknown-linux-gnu-freethreaded+pgo+lto-full.tar.zst",
    "fff6  cpython-3.12.9+20260303-x86_64-unknown-linux-gnu-install_only.tar.gz",
    "",
    "not a manifest line",
])

_LINUX_GNU = "x86_64-unknown-linux-gnu"

def _resolve_modes_test_impl(ctx):
    env = unittest.begin(ctx)

    modes = extension_testlib.resolve_modes("install_only")
    asserts.equals(env, 2, len(modes))

    default = modes[0]
    asserts.equals(env, "default", default["name"])
    asserts.equals(env, "", default["repo_suffix"])
    asserts.false(env, default["freethreaded"])
    for platform in PLATFORMS:
        config = default["config_for_platform"][platform]
        asserts.equals(env, "install_only", config["suffix"], platform)
        asserts.equals(env, "", config["abi_flags"], platform)

    ft = modes[1]
    asserts.equals(env, "freethreaded", ft["name"])
    asserts.equals(env, "freethreaded", ft["repo_suffix"])
    asserts.true(env, ft["freethreaded"])

    # Each platform's free-threaded config is parsed from its own PBS suffix,
    # independent of build_config.
    for platform in PLATFORMS:
        config = ft["config_for_platform"][platform]
        asserts.equals(env, "tar.zst", config["extension"], platform)
        asserts.equals(env, "python/install", config["strip_prefix"], platform)
        asserts.equals(env, "t", config["abi_flags"], platform)
    asserts.equals(env, "freethreaded+pgo+lto-full", ft["config_for_platform"][_LINUX_GNU]["suffix"])
    asserts.equals(env, "freethreaded+lto-full", ft["config_for_platform"]["x86_64-unknown-linux-musl"]["suffix"])
    asserts.equals(env, "freethreaded+pgo-full", ft["config_for_platform"]["x86_64-pc-windows-msvc"]["suffix"])

    debug = extension_testlib.resolve_modes("debug-full")[0]["config_for_platform"][_LINUX_GNU]
    asserts.equals(env, "tar.zst", debug["extension"])
    asserts.equals(env, "python/install", debug["strip_prefix"])
    asserts.equals(env, "d", debug["abi_flags"])
    asserts.equals(env, "debug-full", debug["suffix"])

    return unittest.end(env)

resolve_modes_test = unittest.make(_resolve_modes_test_impl)

def _parse_sha256sums_test_impl(ctx):
    env = unittest.begin(ctx)

    modes = extension_testlib.resolve_modes("install_only")
    index = extension_testlib.parse_sha256sums(_SHA256SUMS, _RELEASE_DATE, modes)

    # Newest patch wins; sibling build configurations must not shadow it.
    default = index["3.13/{}/default".format(_LINUX_GNU)]
    asserts.equals(env, "bbb2", default["sha256"])
    asserts.equals(env, "3.13.2", default["full_version"])

    ft = index["3.13/{}/freethreaded".format(_LINUX_GNU)]
    asserts.equals(env, "eee5", ft["sha256"])

    asserts.equals(env, "fff6", index["3.12/{}/default".format(_LINUX_GNU)]["sha256"])
    asserts.false(env, "3.12/{}/freethreaded".format(_LINUX_GNU) in index)

    return unittest.end(env)

parse_sha256sums_test = unittest.make(_parse_sha256sums_test_impl)

def _parse_sha256sums_build_config_test_impl(ctx):
    env = unittest.begin(ctx)

    # The default mode's asset follows build_config, and the free-threaded
    # entry is identical across configurations.
    for build_config, want_sha in [("install_only_stripped", "ccc3"), ("debug-full", "ddd4")]:
        modes = extension_testlib.resolve_modes(build_config)
        index = extension_testlib.parse_sha256sums(_SHA256SUMS, _RELEASE_DATE, modes)
        asserts.equals(env, want_sha, index["3.13/{}/default".format(_LINUX_GNU)]["sha256"], build_config)
        asserts.equals(env, "eee5", index["3.13/{}/freethreaded".format(_LINUX_GNU)]["sha256"], build_config)
        asserts.false(env, "3.12/{}/default".format(_LINUX_GNU) in index, build_config)

    return unittest.end(env)

parse_sha256sums_build_config_test = unittest.make(_parse_sha256sums_build_config_test_impl)

def extension_test_suite():
    unittest.suite(
        "extension_tests",
        resolve_modes_test,
        parse_sha256sums_test,
        parse_sha256sums_build_config_test,
    )
