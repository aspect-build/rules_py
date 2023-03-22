import os


def test_env(env, expected):
    assert env in os.environ, f"Expected environ to have key '{env}'"

    _actual = os.environ.get(env)
    assert _actual == expected, f"Expected environ key '{env}' to equal '{expected}', but got '{_actual}'"


test_env('ONE', 'un')
test_env('TWO', 'deux')
test_env('LOCATION', "py/tests/py-test/test_env_vars.py")
test_env('DEFINE', "SOME_VALUE")
try:
    test_env('BAZEL_TARGET', "@//py/tests/py-test:test_env_vars")
except AssertionError:
    # This behavior changes with bazel 6, it now inserts the @ symbol to ctx.label
    # Use this assertion so that either test form will pass
    test_env('BAZEL_TARGET', "//py/tests/py-test:test_env_vars")
test_env('BAZEL_WORKSPACE', "aspect_rules_py")
test_env('BAZEL_TARGET_NAME', "test_env_vars")
