"""Analysis test for metadata-free wheel identity."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:providers.bzl", "PyWheelsInfo")

def _metadata_free_wheel_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.true(env, PyWheelsInfo in target)
    if PyWheelsInfo in target:
        wheels = target[PyWheelsInfo].wheels.to_list()
        asserts.equals(env, 1, len(wheels))
        if wheels:
            wheel = wheels[0]
            asserts.equals(env, (), wheel.top_levels)
            asserts.equals(env, (), wheel.console_scripts)
            asserts.true(env, wheel.install_tree in target[DefaultInfo].files.to_list())

    return analysistest.end(env)

metadata_free_wheel_test = analysistest.make(_metadata_free_wheel_test_impl)
