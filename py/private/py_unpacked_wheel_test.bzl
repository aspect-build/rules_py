"""Analysis tests for py_unpacked_wheel metadata validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load(":providers.bzl", "PyWheelsInfo")
load(":py_unpacked_wheel.bzl", "py_unpacked_wheel")

def _metadata_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    wheel = target[PyWheelsInfo].wheels.to_list()[0]
    asserts.equals(env, target.label, wheel.install_tree.owner)
    asserts.equals(env, ctx.attr.layout_known, wheel.layout_known)
    asserts.equals(env, tuple(ctx.attr.top_levels), wheel.top_levels)
    asserts.equals(env, tuple(ctx.attr.directory_top_levels), wheel.directory_top_levels)
    asserts.equals(env, tuple(ctx.attr.namespace_top_levels), wheel.namespace_top_levels)
    asserts.equals(env, tuple(ctx.attr.namespace_entries), wheel.namespace_entries)
    asserts.equals(env, (), wheel.namespace_dirs)
    asserts.equals(env, (), wheel.regular_roots)
    asserts.equals(env, tuple(ctx.attr.console_scripts), wheel.console_scripts)
    asserts.equals(env, ctx.attr.scripts_known, wheel.scripts_known)
    actions = [action for action in target.actions if action.mnemonic == "PyUnpackedWheel"]
    asserts.equals(env, 1, len(actions))
    if actions:
        metadata_args = [
            actions[0].argv[index + 1]
            for index in range(len(actions[0].argv) - 1)
            if actions[0].argv[index] == "--expected-metadata"
        ]
        origin_args = [
            actions[0].argv[index + 1]
            for index in range(len(actions[0].argv) - 1)
            if actions[0].argv[index] == "--expected-metadata-origin"
        ]
        asserts.equals(env, 1 if ctx.attr.layout_known or ctx.attr.scripts_known else 0, len(metadata_args))
        asserts.equals(env, len(metadata_args), len(origin_args))
        if origin_args:
            asserts.equals(env, str(target.label), origin_args[0])
        if metadata_args:
            expected = json.decode(metadata_args[0])
            asserts.equals(env, ctx.attr.layout_known, "top_levels" in expected)
            asserts.equals(
                env,
                ctx.attr.scripts_known,
                "console_scripts" in expected,
            )
            if ctx.attr.scripts_known:
                asserts.equals(env, ctx.attr.console_scripts, expected.get("console_scripts"))
    return analysistest.end(env)

_metadata_test = analysistest.make(
    _metadata_test_impl,
    attrs = {
        "console_scripts": attr.string_list(),
        "directory_top_levels": attr.string_list(),
        "layout_known": attr.bool(mandatory = True),
        "namespace_entries": attr.string_list(),
        "namespace_top_levels": attr.string_list(),
        "scripts_known": attr.bool(mandatory = True),
        "top_levels": attr.string_list(),
    },
)

def _metadata_absent_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.false(
        env,
        PyWheelsInfo in target,
        "a wheel with unknown layout and scripts must retain no-provider fallback",
    )
    return analysistest.end(env)

_metadata_absent_test = analysistest.make(_metadata_absent_test_impl)

def _metadata_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_metadata_failure_test = analysistest.make(
    _metadata_failure_test_impl,
    attrs = {"expected_error": attr.string()},
    expect_failure = True,
)

def py_unpacked_wheel_test_suite():
    write_file(
        name = "_py_unpacked_wheel_fixture_file",
        out = "py_unpacked_wheel_fixture.whl",
        content = [""],
        tags = ["manual"],
    )
    py_unpacked_wheel(
        name = "_py_unpacked_wheel_empty_scripts_fixture",
        src = ":_py_unpacked_wheel_fixture_file",
        console_scripts_known = True,
        directory_top_levels = ["fixture", "fixture_ns"],
        namespace_entries = ["fixture_ns/package"],
        namespace_top_levels = ["fixture_ns"],
        tags = ["manual"],
        top_levels = ["fixture", "fixture_ns"],
    )
    _metadata_test(
        name = "py_unpacked_wheel_empty_scripts_test",
        directory_top_levels = ["fixture", "fixture_ns"],
        layout_known = True,
        namespace_entries = ["fixture_ns/package"],
        namespace_top_levels = ["fixture_ns"],
        scripts_known = True,
        target_under_test = ":_py_unpacked_wheel_empty_scripts_fixture",
        top_levels = ["fixture", "fixture_ns"],
    )
    py_unpacked_wheel(
        name = "_py_unpacked_wheel_unknown_scripts_fixture",
        src = ":_py_unpacked_wheel_fixture_file",
        tags = ["manual"],
        top_levels = ["fixture"],
    )
    _metadata_test(
        name = "py_unpacked_wheel_unknown_scripts_test",
        layout_known = True,
        scripts_known = False,
        target_under_test = ":_py_unpacked_wheel_unknown_scripts_fixture",
        top_levels = ["fixture"],
    )
    py_unpacked_wheel(
        name = "_py_unpacked_wheel_script_only_fixture",
        src = ":_py_unpacked_wheel_fixture_file",
        console_scripts = ["fixture=fixture:main"],
        tags = ["manual"],
    )
    _metadata_test(
        name = "py_unpacked_wheel_script_only_test",
        console_scripts = ["fixture=fixture:main"],
        layout_known = False,
        scripts_known = True,
        target_under_test = ":_py_unpacked_wheel_script_only_fixture",
    )
    py_unpacked_wheel(
        name = "_py_unpacked_wheel_unknown_metadata_fixture",
        src = ":_py_unpacked_wheel_fixture_file",
        tags = ["manual"],
    )
    _metadata_absent_test(
        name = "py_unpacked_wheel_unknown_metadata_test",
        target_under_test = ":_py_unpacked_wheel_unknown_metadata_fixture",
    )
    py_unpacked_wheel(
        name = "_py_unpacked_wheel_invalid_directory_fixture",
        src = ":_py_unpacked_wheel_fixture_file",
        directory_top_levels = ["other"],
        tags = ["manual"],
        top_levels = ["fixture"],
    )
    _metadata_failure_test(
        name = "py_unpacked_wheel_invalid_directory_test",
        expected_error = "directory_top_levels entries are absent from top_levels: [\"other\"]",
        target_under_test = ":_py_unpacked_wheel_invalid_directory_fixture",
    )
