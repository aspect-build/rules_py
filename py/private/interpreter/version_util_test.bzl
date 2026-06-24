"""Tests for version_util.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:version_util.bzl", "is_pre_release", "version_gt", "version_key")

def _version_key_test_impl(ctx):
    env = unittest.begin(ctx)

    # Simple numeric versions
    asserts.equals(env, [(3, 3, 0), (12, 3, 0), (3, 3, 0)], version_key("3.12.3"))

    # Pre-release: alpha
    asserts.equals(env, [(3, 3, 0), (15, 3, 0), (0, 0, 6)], version_key("3.15.0a6"))

    # Pre-release: beta
    asserts.equals(env, [(3, 3, 0), (14, 3, 0), (0, 1, 1)], version_key("3.14.0b1"))

    # Pre-release: rc
    asserts.equals(env, [(3, 3, 0), (14, 3, 0), (0, 2, 2)], version_key("3.14.0rc2"))

    # Final release (no suffix) has higher phase than any pre-release
    key_final = version_key("3.15.0")
    key_alpha = version_key("3.15.0a1")
    asserts.true(env, key_final[2] > key_alpha[2], "final release should sort after alpha")

    return unittest.end(env)

version_key_test = unittest.make(_version_key_test_impl)

def _version_gt_basic_test_impl(ctx):
    env = unittest.begin(ctx)

    # Patch version comparison
    asserts.true(env, version_gt("3.12.4", "3.12.3"))
    asserts.false(env, version_gt("3.12.3", "3.12.4"))
    asserts.false(env, version_gt("3.12.3", "3.12.3"))

    # Minor version comparison
    asserts.true(env, version_gt("3.13.0", "3.12.9"))
    asserts.false(env, version_gt("3.12.9", "3.13.0"))

    # Major version comparison
    asserts.true(env, version_gt("4.0.0", "3.99.99"))

    return unittest.end(env)

version_gt_basic_test = unittest.make(_version_gt_basic_test_impl)

def _version_gt_prerelease_test_impl(ctx):
    env = unittest.begin(ctx)

    # Pre-release ordering: alpha < beta < rc < release
    asserts.true(env, version_gt("3.15.0b1", "3.15.0a6"))
    asserts.true(env, version_gt("3.15.0rc1", "3.15.0b1"))
    asserts.true(env, version_gt("3.15.0", "3.15.0rc1"))

    # Same phase, different number
    asserts.true(env, version_gt("3.15.0a6", "3.15.0a5"))
    asserts.false(env, version_gt("3.15.0a5", "3.15.0a6"))

    # Alpha of next minor > final of previous minor
    asserts.true(env, version_gt("3.16.0a1", "3.15.0"))

    # Final release > any pre-release of same version
    asserts.true(env, version_gt("3.15.0", "3.15.0a99"))
    asserts.true(env, version_gt("3.15.0", "3.15.0b99"))
    asserts.true(env, version_gt("3.15.0", "3.15.0rc99"))

    return unittest.end(env)

version_gt_prerelease_test = unittest.make(_version_gt_prerelease_test_impl)

def _version_gt_padding_test_impl(ctx):
    env = unittest.begin(ctx)

    # Different length versions (padding with release-level zeros)
    asserts.false(env, version_gt("3.12", "3.12.0"))
    asserts.false(env, version_gt("3.12.0", "3.12"))
    asserts.true(env, version_gt("3.12.1", "3.12"))
    asserts.true(env, version_gt("3.13", "3.12.9"))

    return unittest.end(env)

version_gt_padding_test = unittest.make(_version_gt_padding_test_impl)

def _is_pre_release_test_impl(ctx):
    env = unittest.begin(ctx)

    # Final releases
    asserts.false(env, is_pre_release("3.12.3"))
    asserts.false(env, is_pre_release("3.15.0"))

    # Alpha
    asserts.true(env, is_pre_release("3.15.0a6"))

    # Beta
    asserts.true(env, is_pre_release("3.14.0b1"))

    # Release candidate
    asserts.true(env, is_pre_release("3.14.0rc2"))

    return unittest.end(env)

is_pre_release_test = unittest.make(_is_pre_release_test_impl)

def version_util_test_suite():
    unittest.suite(
        "version_util_tests",
        version_key_test,
        version_gt_basic_test,
        version_gt_prerelease_test,
        version_gt_padding_test,
        is_pre_release_test,
    )
