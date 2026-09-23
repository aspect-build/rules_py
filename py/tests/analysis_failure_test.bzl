"""Asserts a target fails analysis with a given diagnostic."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _analysis_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

analysis_failure_test = analysistest.make(
    _analysis_failure_test_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)
