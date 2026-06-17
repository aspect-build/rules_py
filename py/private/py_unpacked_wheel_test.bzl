"""Analysis tests for py_unpacked_wheel metadata."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(":providers.bzl", "PyWheelsInfo")

def _py_unpacked_wheel_topology_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, PyWheelsInfo in target)
    if PyWheelsInfo in target:
        wheels = target[PyWheelsInfo].wheels.to_list()
        asserts.equals(env, 1, len(wheels))
        if len(wheels) == 1:
            asserts.equals(env, ctx.attr.expected, wheels[0].topology_known)
    return analysistest.end(env)

py_unpacked_wheel_topology_test = analysistest.make(
    _py_unpacked_wheel_topology_test_impl,
    attrs = {"expected": attr.bool(mandatory = True)},
)
