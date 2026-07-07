"""Tests for parse_whl_name.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":parse_whl_name.bzl", "normalize_abi_tag", "normalize_platform_tag", "parse_whl_name")

def _normalize_platform_tag_test_impl(ctx):
    env = unittest.begin(ctx)

    # PEP 600 legacy aliases resolve to their modern equivalents.
    asserts.equals(env, "manylinux_2_17_x86_64", normalize_platform_tag("manylinux2014_x86_64"))
    asserts.equals(env, "manylinux_2_12_i686", normalize_platform_tag("manylinux2010_i686"))
    asserts.equals(env, "manylinux_2_5_x86_64", normalize_platform_tag("manylinux1_x86_64"))

    # A legacy alias alongside its modern spelling dedupes to one tag.
    asserts.equals(
        env,
        "manylinux_2_17_aarch64",
        normalize_platform_tag("manylinux2014_aarch64.manylinux_2_17_aarch64"),
    )

    # Non-legacy tags pass through untouched, preserving order.
    asserts.equals(env, "macosx_11_0_arm64", normalize_platform_tag("macosx_11_0_arm64"))
    asserts.equals(
        env,
        "musllinux_1_2_x86_64.manylinux_2_17_x86_64",
        normalize_platform_tag("musllinux_1_2_x86_64.manylinux2014_x86_64"),
    )

    return unittest.end(env)

normalize_platform_tag_test = unittest.make(_normalize_platform_tag_test_impl)

def _normalize_abi_tag_test_impl(ctx):
    env = unittest.begin(ctx)

    # Tags without trailing feature flags are untouched.
    asserts.equals(env, "abi3", normalize_abi_tag("abi3"))
    asserts.equals(env, "none", normalize_abi_tag("none"))
    asserts.equals(env, "cp310", normalize_abi_tag("cp310"))

    # Feature flags normalize to a stable d/m/t/u order.
    asserts.equals(env, "cp313t", normalize_abi_tag("cp313t"))
    asserts.equals(env, "cp39dm", normalize_abi_tag("cp39md"))
    asserts.equals(env, "cp39dmu", normalize_abi_tag("cp39umd"))

    return unittest.end(env)

normalize_abi_tag_test = unittest.make(_normalize_abi_tag_test_impl)

def _parse_whl_name_test_impl(ctx):
    env = unittest.begin(ctx)

    # Common pure-python wheel: compound python tag, no build tag.
    parsed = parse_whl_name("six-1.17.0-py2.py3-none-any.whl")
    asserts.equals(env, "six", parsed.project)
    asserts.equals(env, "1.17.0", parsed.version)
    asserts.equals(env, None, parsed.build)
    asserts.equals(env, ["py2", "py3"], parsed.python_tags)
    asserts.equals(env, ["none"], parsed.abi_tags)
    asserts.equals(env, ["any"], parsed.platform_tags)

    # Build tag between version and python tag.
    parsed = parse_whl_name("mypkg-1.0-2foo-py3-none-any.whl")
    asserts.equals(env, "mypkg", parsed.project)
    asserts.equals(env, "1.0", parsed.version)
    asserts.equals(env, "2foo", parsed.build)

    # Native wheel with a legacy platform alias and a freethreaded ABI:
    # the alias normalizes and dedupes against its modern spelling.
    parsed = parse_whl_name(
        "regex-2024.11.6-cp313-cp313t-manylinux2014_x86_64.manylinux_2_17_x86_64.whl",
    )
    asserts.equals(env, ["cp313"], parsed.python_tags)
    asserts.equals(env, ["cp313t"], parsed.abi_tags)
    asserts.equals(env, ["manylinux_2_17_x86_64"], parsed.platform_tags)

    return unittest.end(env)

parse_whl_name_test = unittest.make(_parse_whl_name_test_impl)

def parse_whl_name_test_suite():
    unittest.suite(
        "parse_whl_name_tests",
        normalize_abi_tag_test,
        normalize_platform_tag_test,
        parse_whl_name_test,
    )
