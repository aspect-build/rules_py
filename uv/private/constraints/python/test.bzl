load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/constraints:defs.bzl", "foreign_interpreter_tag")
load(":defs.bzl", "PYTHON_TAGS", "supported_python")

# -- supported_python: accepted tags -------------------------------------------

def _generated_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    for tag in PYTHON_TAGS:
        asserts.true(env, supported_python(tag), "generated tag %s should be supported" % tag)
    for tag in [
        "py3",
        "cp3",
        "py2",
        "cp27",
        "py311",
        "cp311",
        "cp313",
        "cp320",
    ]:
        asserts.true(env, supported_python(tag), "tag %s should be supported" % tag)
    return unittest.end(env)

generated_tags_test = unittest.make(_generated_tags_test_impl)

# -- supported_python: rejected tags -------------------------------------------

def _reject_malformed_tags_test_impl(ctx):
    """Regression: malformed tags like cp311_2 (renamed wheels) have no config_setting target and must be rejected."""
    env = unittest.begin(ctx)
    asserts.false(env, supported_python("cp311_2"), "cp311_2 must not be supported")
    asserts.false(env, supported_python("cp999"), "cp999 has no generated target")
    asserts.false(env, supported_python("cp321"), "minor 21 is outside the generated range")
    asserts.false(env, supported_python("py4"), "there is no Python 4")
    asserts.false(env, supported_python("python3"), "python3 is not a valid tag")
    asserts.false(env, supported_python("cp"), "bare interpreter prefix should be rejected")
    asserts.false(env, supported_python(""), "empty tag should be rejected")
    return unittest.end(env)

reject_malformed_tags_test = unittest.make(_reject_malformed_tags_test_impl)

def _reject_foreign_interpreters_test_impl(ctx):
    env = unittest.begin(ctx)
    for tag in [
        "pp310",
        "pypy310",
        "graalpy311",
        "ip27",
        "jy27",
    ]:
        asserts.false(env, supported_python(tag), "foreign interpreter tag %s should be rejected" % tag)
        asserts.true(env, foreign_interpreter_tag(tag), "tag %s should be classified as foreign (silent skip)" % tag)
    return unittest.end(env)

reject_foreign_interpreters_test = unittest.make(_reject_foreign_interpreters_test_impl)

def _foreign_classification_test_impl(ctx):
    """Malformed CPython/generic tags are NOT foreign, so skipping them warns."""
    env = unittest.begin(ctx)
    asserts.false(env, foreign_interpreter_tag("cp311_2"), "cp311_2 should warn, not skip silently")
    asserts.false(env, foreign_interpreter_tag("cp999"), "cp999 should warn, not skip silently")
    asserts.false(env, foreign_interpreter_tag("cp311"), "cp311 is not foreign")
    asserts.false(env, foreign_interpreter_tag("py3"), "py3 is not foreign")
    return unittest.end(env)

foreign_classification_test = unittest.make(_foreign_classification_test_impl)

# -- Suite ---------------------------------------------------------------------

def python_suite():
    unittest.suite(
        "python_tests",
        generated_tags_test,
        reject_malformed_tags_test,
        reject_foreign_interpreters_test,
        foreign_classification_test,
    )
