"""Analysis test for wheel metadata across equivalent URL spellings."""

load("@aspect_rules_py//py/private:providers.bzl", "PyWheelsInfo")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_PYTHON_VERSION_FLAG = str(Label("@rules_python//python/config_settings:python_version"))
_TARGET_PLATFORM = str(Label("//cases/uv-plus-version:linux_x86_64"))

def _wheel_metadata_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, PyWheelsInfo in target)
    if PyWheelsInfo in target:
        wheels = target[PyWheelsInfo].wheels.to_list()
        asserts.equals(env, 1, len(wheels))
        if wheels:
            asserts.true(env, "jaxlib" in wheels[0].top_levels)
    return analysistest.end(env)

wheel_metadata_test = analysistest.make(
    _wheel_metadata_test_impl,
    config_settings = {
        "//command_line_option:platforms": _TARGET_PLATFORM,
        _PYTHON_VERSION_FLAG: "3.12",
    },
)
