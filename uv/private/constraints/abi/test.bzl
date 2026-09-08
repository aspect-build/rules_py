load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "ABI_FEATURE_SUFFIXES", "ABI_TAGS", "supported_abi")

# -- supported_abi: accepted tags ------------------------------------------------

def _generated_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    for tag in ABI_TAGS:
        asserts.true(env, supported_abi(tag), "generated tag %s should be supported" % tag)
    for tag in [
        "none",
        "abi3",
        "cp311",
        "py311",
        "cp313t",
        "cp39d",
        "cp311dm",
        "cp312dmtu",
    ]:
        asserts.true(env, supported_abi(tag), "tag %s should be supported" % tag)
    return unittest.end(env)

generated_tags_test = unittest.make(_generated_tags_test_impl)

def _feature_suffixes_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 16, len(ABI_FEATURE_SUFFIXES), "d/m/t/u should combine into 16 ordered subsets")
    asserts.true(env, "" in ABI_FEATURE_SUFFIXES, "the bare abi tag (no features) must be generated")
    asserts.true(env, "dmtu" in ABI_FEATURE_SUFFIXES, "the full feature suffix must be generated")
    return unittest.end(env)

feature_suffixes_test = unittest.make(_feature_suffixes_test_impl)

# -- supported_abi: rejected tags ------------------------------------------------

def _reject_malformed_tags_test_impl(ctx):
    """Regression: malformed tags like cp311_2 (renamed wheels) have no config_setting_group target and must be rejected."""
    env = unittest.begin(ctx)
    asserts.false(env, supported_abi("cp311_2"), "cp311_2 must not be supported")
    asserts.false(env, supported_abi("cp999"), "cp999 has no generated target")
    asserts.false(env, supported_abi("cp3"), "abi tags without a minor version are not generated")
    asserts.false(env, supported_abi("cp311td"), "feature letters out of canonical dmtu order are not generated")
    asserts.false(env, supported_abi("cp311x"), "unknown feature letters are not generated")
    asserts.false(env, supported_abi("any"), "any is a platform tag, not an abi tag")
    asserts.false(env, supported_abi(""), "empty tag should be rejected")
    return unittest.end(env)

reject_malformed_tags_test = unittest.make(_reject_malformed_tags_test_impl)

def _reject_foreign_abis_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, supported_abi("pypy310_pp73"), "pypy abi tags should be rejected")
    asserts.false(env, supported_abi("pp73"), "pypy abi tags should be rejected")
    asserts.false(env, supported_abi("graalpy240_311_native"), "graalpy abi tags should be rejected")
    return unittest.end(env)

reject_foreign_abis_test = unittest.make(_reject_foreign_abis_test_impl)

# -- Suite -----------------------------------------------------------------------

def abi_suite():
    unittest.suite(
        "abi_tests",
        generated_tags_test,
        feature_suffixes_test,
        reject_malformed_tags_test,
        reject_foreign_abis_test,
    )
