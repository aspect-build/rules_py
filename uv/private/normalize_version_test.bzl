"""Tests for normalize_version.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":normalize_version.bzl", "normalize_version")

# Bazel repo-name components may only contain these characters.
_VALID_REPO_NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."

def _is_valid_repo_name_component(s):
    for i in range(len(s)):
        if s[i] not in _VALID_REPO_NAME_CHARS:
            return False
    return True

def _normalize_version_epoch_test_impl(ctx):
    """PEP 440 epoch versions (e.g. ``1!2.0``) must not leak ``!`` into repo names."""
    env = unittest.begin(ctx)
    out = normalize_version("1!2.0")
    asserts.true(
        env,
        _is_valid_repo_name_component(out),
        "normalize_version(%r) = %r contains characters invalid in a Bazel repo name" % ("1!2.0", out),
    )
    return unittest.end(env)

normalize_version_epoch_test = unittest.make(_normalize_version_epoch_test_impl)

def _normalize_version_local_test_impl(ctx):
    """PEP 440 local versions (e.g. ``0.4.25+cuda11.cudnn86``) must not leak ``+`` into repo names."""
    env = unittest.begin(ctx)
    version = "0.4.25+cuda11.cudnn86"
    out = normalize_version(version)
    asserts.true(
        env,
        _is_valid_repo_name_component(out),
        "normalize_version(%r) = %r contains characters invalid in a Bazel repo name" % (version, out),
    )
    asserts.false(env, "+" in out, "normalize_version(%r) = %r must not retain '+'" % (version, out))
    return unittest.end(env)

normalize_version_local_test = unittest.make(_normalize_version_local_test_impl)

def normalize_version_test_suite():
    unittest.suite(
        "normalize_version_tests",
        normalize_version_epoch_test,
        normalize_version_local_test,
    )
