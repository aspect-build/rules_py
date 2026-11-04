"""Analysis tests for the public bytecode compiler toolchain rule."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _standalone_tool_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compiler = target[platform_common.ToolchainInfo].pyc_compiler

    asserts.equals(env, [], compiler.arguments)
    asserts.equals(env, None, compiler.runtime)
    asserts.false(env, compiler.supports_workers)
    asserts.equals(env, "fake_pyc_compiler", compiler.executable.executable.basename)
    return analysistest.end(env)

standalone_tool_test = analysistest.make(_standalone_tool_test_impl)

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

failure_test = analysistest.make(
    _failure_test_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)
