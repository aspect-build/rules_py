"""Analysis-only regression for abi3 exclusion from free-threaded Python."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_CONFIG_SETTINGS = {
    "//command_line_option:platforms": str(Label("//uv-abi3-compat-853:linux_x86_64")),
    str(Label("@aspect_rules_py//py/private/interpreter:python_version")): "3.14",
    # The sdist build tool resolves its dependencies through the project hub.
    str(Label("@aspect_rules_py//uv/private/constraints/dep_group:dep_group")): "abi3-compat",
}
_FREETHREADED = str(Label("@aspect_rules_py//py/private/interpreter:freethreaded"))

def _abi3_wheel_test_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    if files:
        asserts.true(env, "-cp311-abi3-" in files[0].basename, files[0].basename)
    return analysistest.end(env)

abi3_wheel_test = analysistest.make(
    _abi3_wheel_test_impl,
    config_settings = _CONFIG_SETTINGS | {_FREETHREADED: False},
)

def _freethreaded_sdist_test_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    if files:
        owner = files[0].owner
        asserts.true(env, owner.repo_name.endswith("sdist_build__abi3_compat__cryptography__46_0_5"), str(owner))
        asserts.equals(env, "whl", owner.name)
    return analysistest.end(env)

freethreaded_sdist_test = analysistest.make(
    _freethreaded_sdist_test_impl,
    config_settings = _CONFIG_SETTINGS | {_FREETHREADED: True},
)
