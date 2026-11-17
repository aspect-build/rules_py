"""Unit tests for the host libc probe in repository.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/host:repository.bzl", "FALLBACK_GLIBC_VERSION", "FALLBACK_MACOS_VERSION", "FALLBACK_MUSL_VERSION", "host_libc", "parse_ldd_version")

def _ldd_glibc_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ("glibc", "2.35"), host_libc("linux", "ldd (Ubuntu GLIBC 2.35-0ubuntu3.8) 2.35\nCopyright (C) 2022\n"))
    asserts.equals(env, ("glibc", "2.39"), host_libc("linux", "ldd (GNU libc) 2.39\n"))
    return unittest.end(env)

ldd_glibc_test = unittest.make(_ldd_glibc_test_impl)

def _ldd_musl_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ("musl", "1.2"), host_libc("linux", "musl libc (x86_64)\nVersion 1.2.5\nDynamic Program Loader\n"))
    return unittest.end(env)

ldd_musl_test = unittest.make(_ldd_musl_test_impl)

def _ldd_unknown_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, parse_ldd_version("something else\n"))
    return unittest.end(env)

ldd_unknown_test = unittest.make(_ldd_unknown_test_impl)

def _no_ldd_test_impl(ctx):
    """Regression: a fetch without `ldd` on PATH used to fail("Unable to determine host libc!")."""
    env = unittest.begin(ctx)
    asserts.equals(env, ("glibc", FALLBACK_GLIBC_VERSION), host_libc("linux", None))
    asserts.equals(env, ("musl", FALLBACK_MUSL_VERSION), host_libc("linux", None, has_musl_loader = True))
    return unittest.end(env)

no_ldd_test = unittest.make(_no_ldd_test_impl)

def _sw_vers_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ("libsystem", "14.5"), host_libc("osx", "14.5\n"))
    asserts.equals(env, ("libsystem", "15.0"), host_libc("osx", "15\n"))
    return unittest.end(env)

sw_vers_test = unittest.make(_sw_vers_test_impl)

def _no_sw_vers_test_impl(ctx):
    """Regression: a fetch without `sw_vers` used to index into empty output."""
    env = unittest.begin(ctx)
    asserts.equals(env, ("libsystem", FALLBACK_MACOS_VERSION), host_libc("osx", None))
    asserts.equals(env, ("libsystem", FALLBACK_MACOS_VERSION), host_libc("osx", ""))
    return unittest.end(env)

no_sw_vers_test = unittest.make(_no_sw_vers_test_impl)

def _windows_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ("msvc", "0.0"), host_libc("windows", None))
    return unittest.end(env)

windows_test = unittest.make(_windows_test_impl)

def host_libc_test_suite():
    unittest.suite(
        "host_libc_tests",
        ldd_glibc_test,
        ldd_musl_test,
        ldd_unknown_test,
        no_ldd_test,
        sw_vers_test,
        no_sw_vers_test,
        windows_test,
    )
