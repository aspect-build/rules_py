"""Check wheel ABI selections with different interpreter versions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_MatchesInfo = provider(fields = ["tags"])

def _matches_impl(ctx):
    return [_MatchesInfo(tags = ctx.attr.tags_matched)]

_matches = rule(
    implementation = _matches_impl,
    attrs = {"tags_matched": attr.string_list()},
)

def _abi_test_impl(ctx):
    env = analysistest.begin(ctx)
    actual = analysistest.target_under_test(env)[_MatchesInfo].tags
    asserts.equals(env, ctx.attr.expected, actual)
    return analysistest.end(env)

_python312_test = analysistest.make(
    _abi_test_impl,
    attrs = {"expected": attr.string_list()},
    config_settings = {"@@//py/private/interpreter:python_version": "3.12"},
)

_python313_test = analysistest.make(
    _abi_test_impl,
    attrs = {"expected": attr.string_list()},
    config_settings = {"@@//py/private/interpreter:python_version": "3.13"},
)

def abi_test_suite(name):
    """Check exact CPython ABIs while preserving abi3 forward compatibility."""
    _matches(
        name = name + "_matches",
        tags_matched = select({
            "//uv/private/constraints/abi:cp311": ["cp311"],
            "//conditions:default": [],
        }) + select({
            "//uv/private/constraints/abi:cp312": ["cp312"],
            "//conditions:default": [],
        }) + select({
            "//uv/private/constraints/abi:cp313": ["cp313"],
            "//conditions:default": [],
        }) + select({
            "//uv/private/constraints/abi:abi3": ["abi3"],
            "//conditions:default": [],
        }),
    )
    _python312_test(
        name = name + "_python312",
        expected = ["cp312", "abi3"],
        target_under_test = ":" + name + "_matches",
    )
    _python313_test(
        name = name + "_python313",
        expected = ["cp313", "abi3"],
        target_under_test = ":" + name + "_matches",
    )
    native.test_suite(
        name = name,
        tests = [name + "_python312", name + "_python313"],
    )
