"""Analysis test for source-built cdifflib wheel metadata propagation."""

load("@aspect_rules_py//py/private:providers.bzl", "PyWheelsInfo")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_DEP_GROUP_FLAG = str(Label("@aspect_rules_py//uv/private/constraints/dep_group:dep_group"))

def _built_wheel_metadata_state_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.true(
        env,
        PyWheelsInfo in target,
        "source-built cdifflib install must expose PyWheelsInfo",
    )
    if PyWheelsInfo in target:
        wheels = target[PyWheelsInfo].wheels.to_list()
        asserts.equals(env, 1, len(wheels), "expected exactly one installed cdifflib wheel")
        if len(wheels) == 1:
            wheel = wheels[0]
            asserts.false(
                env,
                wheel.layout_known,
                "all-empty metadata must leave cdifflib layout unknown",
            )
            asserts.true(
                env,
                wheel.scripts_known,
                "explicit all-empty metadata must preserve known-empty scripts",
            )
            asserts.equals(
                env,
                (),
                wheel.console_scripts,
                "cdifflib declaration must advertise no console scripts",
            )

    return analysistest.end(env)

built_wheel_metadata_state_test = analysistest.make(
    _built_wheel_metadata_state_test_impl,
    config_settings = {
        _DEP_GROUP_FLAG: "uv_pyproject_cases",
    },
)
