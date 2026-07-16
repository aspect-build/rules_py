"""Tests for versions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:versions.bzl", "PLATFORMS", "parse_build_config")

def _parse_build_config_install_only_test_impl(ctx):
    env = unittest.begin(ctx)

    got = parse_build_config("install_only")
    asserts.equals(env, "tar.gz", got["extension"])
    asserts.equals(env, "python", got["strip_prefix"])
    asserts.equals(env, "", got["abi_flags"])
    asserts.false(env, got["freethreaded"])
    asserts.false(env, got["debug"])
    asserts.false(env, got["static"])

    # Stripped is the same interpreter, same ABI, smaller download.
    stripped = parse_build_config("install_only_stripped")
    asserts.equals(env, "tar.gz", stripped["extension"])
    asserts.equals(env, "python", stripped["strip_prefix"])
    asserts.equals(env, "", stripped["abi_flags"])
    asserts.equals(env, "install_only_stripped", stripped["suffix"])

    return unittest.end(env)

parse_build_config_install_only_test = unittest.make(_parse_build_config_install_only_test_impl)

def _parse_build_config_full_test_impl(ctx):
    env = unittest.begin(ctx)

    # Full archives extract from python/install and are zstd-compressed.
    for suffix in ["noopt-full", "lto-full", "pgo-full", "pgo+lto-full"]:
        got = parse_build_config(suffix)
        asserts.equals(env, "tar.zst", got["extension"], suffix)
        asserts.equals(env, "python/install", got["strip_prefix"], suffix)
        asserts.equals(env, "", got["abi_flags"], suffix)
        asserts.false(env, got["freethreaded"], suffix)

    return unittest.end(env)

parse_build_config_full_test = unittest.make(_parse_build_config_full_test_impl)

def _parse_build_config_abi_flags_test_impl(ctx):
    env = unittest.begin(ctx)

    # debug => Py_DEBUG => "d"
    asserts.equals(env, "d", parse_build_config("debug-full")["abi_flags"])

    # freethreaded => "t"
    ft = parse_build_config("freethreaded+pgo+lto-full")
    asserts.equals(env, "t", ft["abi_flags"])
    asserts.true(env, ft["freethreaded"])

    # freethreaded + debug => "td"
    ftd = parse_build_config("freethreaded+debug-full")
    asserts.equals(env, "td", ftd["abi_flags"])
    asserts.true(env, ftd["freethreaded"])
    asserts.true(env, ftd["debug"])

    return unittest.end(env)

parse_build_config_abi_flags_test = unittest.make(_parse_build_config_abi_flags_test_impl)

def _parse_build_config_static_test_impl(ctx):
    env = unittest.begin(ctx)

    # Static parses (validate_build_config rejects it, but the parser reports it).
    got = parse_build_config("debug+static-full")
    asserts.true(env, got["static"])
    asserts.true(env, got["debug"])

    asserts.true(env, parse_build_config("lto+static-full")["static"])

    return unittest.end(env)

parse_build_config_static_test = unittest.make(_parse_build_config_static_test_impl)

def _parse_build_config_invalid_test_impl(ctx):
    env = unittest.begin(ctx)

    # Not a known packaging and no -full suffix.
    asserts.equals(env, None, parse_build_config("install"))
    asserts.equals(env, None, parse_build_config("optimized"))
    asserts.equals(env, None, parse_build_config(""))

    # Unknown optimization token inside a -full suffix.
    asserts.equals(env, None, parse_build_config("bogus-full"))
    asserts.equals(env, None, parse_build_config("pgo+bogus-full"))
    asserts.equals(env, None, parse_build_config("-full"))

    # Tokens must follow PBS's canonical filename order; a misordered suffix
    # parses under a looser grammar but can never match a published asset.
    asserts.equals(env, None, parse_build_config("pgo+freethreaded-full"))
    asserts.equals(env, None, parse_build_config("lto+pgo-full"))
    asserts.equals(env, None, parse_build_config("static+lto-full"))
    asserts.equals(env, None, parse_build_config("lto+debug-full"))

    # Duplicate tokens never appear in manifests.
    asserts.equals(env, None, parse_build_config("pgo+pgo-full"))

    return unittest.end(env)

parse_build_config_invalid_test = unittest.make(_parse_build_config_invalid_test_impl)

def _parse_build_config_platform_suffixes_test_impl(ctx):
    env = unittest.begin(ctx)

    # The extension parses every platform's freethreaded_suffix, so each entry
    # in PLATFORMS must stay within the grammar.
    for platform, info in PLATFORMS.items():
        got = parse_build_config(info["freethreaded_suffix"])
        asserts.true(env, got != None, platform)
        asserts.true(env, got["freethreaded"], platform)

    return unittest.end(env)

parse_build_config_platform_suffixes_test = unittest.make(_parse_build_config_platform_suffixes_test_impl)

def versions_test_suite():
    unittest.suite(
        "versions_tests",
        parse_build_config_install_only_test,
        parse_build_config_full_test,
        parse_build_config_abi_flags_test,
        parse_build_config_static_test,
        parse_build_config_invalid_test,
        parse_build_config_platform_suffixes_test,
    )
