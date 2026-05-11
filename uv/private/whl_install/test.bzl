load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository.bzl", "compatible_python_tags", "select_key", "sort_select_arms", "source_specificity")

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

def _abi3_compatibility_test_impl(ctx):
    env = unittest.begin(ctx)

    # cp<X>-abi3 expands forward across supported CPython minors.
    asserts.equals(
        env,
        ["cp3{}".format(m) for m in range(10, 21)],
        compatible_python_tags("cp310", "abi3"),
    )

    # Non-abi3 wheels are not expanded.
    asserts.equals(
        env,
        ["cp310"],
        compatible_python_tags("cp310", "cp310"),
    )

    # abi3 forward-compat is CPython-only; py-prefixed tags pass through.
    asserts.equals(
        env,
        ["py3"],
        compatible_python_tags("py3", "abi3"),
    )

    return unittest.end(env)

abi3_compatibility_test = unittest.make(
    _abi3_compatibility_test_impl,
)

def _source_specificity_test_impl(ctx):
    env = unittest.begin(ctx)

    # Higher minor = more specific. Disambiguates two abi3 wheels that
    # expand into the same compatible_python_tag (cp38-abi3 and cp311-abi3
    # both cover cp312+; cp311 wins).
    asserts.true(env, source_specificity("cp311") > source_specificity("cp38"))
    asserts.true(env, source_specificity("cp312") > source_specificity("cp311"))

    # Non-cp tags don't participate in abi3 expansion; score them lowest
    # so they never beat a cp source on conflict.
    asserts.true(env, source_specificity("cp38") > source_specificity("py3"))

    return unittest.end(env)

source_specificity_test = unittest.make(
    _source_specificity_test_impl,
)

def whl_install_suite():
    unittest.suite(
        "whl_sorting_tests",
        whl_sorting_test,
    )
    unittest.suite(
        "abi3_compatibility_tests",
        abi3_compatibility_test,
    )
    unittest.suite(
        "source_specificity_tests",
        source_specificity_test,
    )
