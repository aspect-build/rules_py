"""pep517_native_whl's exec-platform selection must keep steering builds
onto platforms that can build the target natively.

With the NATIVE_BUILD_TOOLCHAIN sentinel (and friends) optional, steering
relies on Bazel preferring the highest-priority execution platform that
satisfies *all* requested toolchain types — optional ones included — over
platforms that satisfy only the mandatory set. These tests pin that
property, because losing it would silently schedule native sdist builds
onto platforms that cannot run them:

- steering: a foreign platform registered ahead of every other candidate
  must lose to a platform matching the target.
- native match preference: with a target-matching platform registered
  *behind* a foreign one, the matching platform must still win.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _native_action_present_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected the native build action: a foreign execution platform must " +
        "lose selection to a platform matching the target",
    )
    return analysistest.end(env)

exec_platform_steering_test = analysistest.make(
    _native_action_present_test_impl,
    config_settings = {
        "//command_line_option:extra_execution_platforms": [
            str(Label("//uv/private/pep517_whl/tests:decoy_exec_platform")),
        ],
    },
)

exec_platform_prefers_native_match_test = analysistest.make(
    _native_action_present_test_impl,
    config_settings = {
        "//command_line_option:platforms": [
            str(Label("//uv/private/pep517_whl/tests:cross_target_platform")),
        ],
        "//command_line_option:extra_execution_platforms": [
            str(Label("//uv/private/pep517_whl/tests:foreign_exec_platform")),
            str(Label("//uv/private/pep517_whl/tests:cross_target_platform")),
        ],
    },
)
