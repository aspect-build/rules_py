load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository.bzl", "select_key", "sort_select_arms")

def _whl_sorting_test_impl(ctx):
    env = unittest.begin(ctx)

    a = ("cp314", "musllinux_1_2_s390x", "cp314")
    at = ("cp314", "musllinux_1_2_s390x", "cp314t")

    # Ensure that the freethreaded wheel scores lowest
    asserts.true(env, select_key(at) > select_key(a))

    # Ensure that the sorted arms put the freethreaded wheel first
    asserts.equals(
        env,
        [
            (at, None),
            (a, None),
        ],
        sort_select_arms({
            a: None,
            at: None,
        }).items(),
    )

    return unittest.end(env)

whl_sorting_test = unittest.make(
    _whl_sorting_test_impl,
)

def whl_install_suite():
    unittest.suite(
        "whl_sorting_tests",
        whl_sorting_test,
    )
