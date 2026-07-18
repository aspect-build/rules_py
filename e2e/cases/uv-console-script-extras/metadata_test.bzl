"""Analysis test asserting `parse_console_script` strips entry-point extras.

`PyWheelsInfo.console_scripts` is produced by `parse_console_script`
(//uv/private/whl_install:repository.bzl) at repo-fetch time. This test pins the
expected, normalised `name=module:func` values for real wheels that ship the
legacy `name = module:func [extra]` syntax, so a regression that lets the
`[extra]` suffix leak back into the value fails here.
"""

load("@aspect_rules_py//py:defs.bzl", "PyWheelsInfo")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _forward_wheels_impl(ctx):
    return [PyWheelsInfo(wheels = depset(order = "postorder", transitive = [
        dep[PyWheelsInfo].wheels
        for dep in ctx.attr.deps
    ]))]

forward_wheels = rule(
    implementation = _forward_wheels_impl,
    attrs = {"deps": attr.label_list(providers = [PyWheelsInfo])},
)

def _console_scripts_metadata_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, PyWheelsInfo in target)
    if PyWheelsInfo in target:
        wheels = target[PyWheelsInfo].wheels.to_list()
        asserts.equals(env, 1, len(wheels))
        if wheels:
            asserts.equals(
                env,
                ctx.attr.expected_console_scripts,
                list(wheels[0].console_scripts),
            )
    return analysistest.end(env)

console_scripts_metadata_test = analysistest.make(
    _console_scripts_metadata_test_impl,
    attrs = {
        "expected_console_scripts": attr.string_list(
            doc = "Expected normalised `name=module:func` entries, extras stripped.",
        ),
    },
)
