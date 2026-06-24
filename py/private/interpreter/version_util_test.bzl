"""Tests for version_util.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:version_util.bzl", "is_pre_release", "parse_version", "version_gt")

def _parse_version_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        struct(
            components = [(3, 3, 0), (15, 3, 0), (0, 0, 6)],
            major = 3,
            micro = 0,
            minor = 15,
            releaselevel = "alpha",
            serial = 6,
        ),
        parse_version("3.15.0a6"),
    )
    asserts.equals(
        env,
        struct(
            components = [(3, 3, 0), (12, 3, 0), (3, 3, 0)],
            major = 3,
            micro = 3,
            minor = 12,
            releaselevel = "final",
            serial = 0,
        ),
        parse_version("3.12.3"),
    )

    beta = parse_version("3.14.0b1")
    asserts.equals(env, "beta", beta.releaselevel)
    asserts.equals(env, 1, beta.serial)

    candidate = parse_version("3.14.0rc2")
    asserts.equals(env, "candidate", candidate.releaselevel)
    asserts.equals(env, 2, candidate.serial)

    final = parse_version("3.15.0")
    alpha = parse_version("3.15.0a1")
    asserts.true(
        env,
        final.components[2] > alpha.components[2],
        "final release should sort after alpha",
    )

    return unittest.end(env)

parse_version_test = unittest.make(_parse_version_test_impl)

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
        parse_version_test,
        version_gt_basic_test,
        version_gt_prerelease_test,
        version_gt_padding_test,
        is_pre_release_test,
    )
