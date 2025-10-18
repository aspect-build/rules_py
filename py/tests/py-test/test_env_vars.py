import os


def test_env(env, expected):
    assert env in os.environ, f"Expected environ to have key '{env}'"

    _actual = os.environ.get(env)
    assert _actual == expected, f"Expected environ key '{env}' to equal '{expected}', but got '{_actual}'"


test_env('ONE', 'un')
test_env('TWO', 'deux')
test_env('LOCATION', "py/tests/py-test/test_env_vars.py")
test_env('DEFINE', "SOME_VALUE")
test_env('BAZEL_TARGET', "//py/tests/py-test:test_env_vars")
test_env('BAZEL_WORKSPACE', "_main")
test_env('BAZEL_TARGET_NAME', "test_env_vars")
