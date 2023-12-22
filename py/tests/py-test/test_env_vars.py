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
# With bzlmod enabled, the main workspace has this hard-coded name.
# See https://bazelbuild.slack.com/archives/C014RARENH0/p1702318129963129?thread_ts=1702288944.560349&cid=C014RARENH0
# Xudong Yang:
# the 'workspace name' is an unfortunate concept laden with historical baggage.
# The better question here might be -- what do you intend to do with the 'workspace name'?
# the name of the execution root directory will always be _main when Bzlmod is enabled.
# similarly, the runfiles dir prefix for the main repo will always be _main.
test_env('BAZEL_WORKSPACE', "_main")
test_env('BAZEL_TARGET_NAME', "test_env_vars")
