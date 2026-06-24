"""Real-rule analysis tests for whl_install .pyc runtime compatibility."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:py_runtime_info.bzl", "PyRuntimeInfo")

def _test_runtime_pair_impl(ctx):
    fields = {
        "py2_runtime": None,
        "py3_runtime": ctx.attr.runtime[PyRuntimeInfo],
    }
    if ctx.attr.pyc_magic_number >= 0:
        fields["pyc_magic_number"] = ctx.attr.pyc_magic_number
    return [platform_common.ToolchainInfo(**fields)]

test_runtime_pair = rule(
    implementation = _test_runtime_pair_impl,
    attrs = {
        "pyc_magic_number": attr.int(default = -1),
        "runtime": attr.label(
            mandatory = True,
            providers = [PyRuntimeInfo],
        ),
    },
)

def _test_exec_tools_impl(ctx):
    return [platform_common.ToolchainInfo(
        exec_tools = struct(
            exec_interpreter = ctx.attr.exec_interpreter,
            exec_runtime = ctx.attr.runtime[PyRuntimeInfo],
            precompiler = None,
        ),
    )]

test_exec_tools = rule(
    implementation = _test_exec_tools_impl,
    attrs = {
        "exec_interpreter": attr.label(),
        "runtime": attr.label(
            mandatory = True,
            providers = [PyRuntimeInfo],
        ),
    },
)

def _incompatible_runtime_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_failure)
    return analysistest.end(env)

_INCOMPATIBLE_TEST_ATTRS = {
    "expected_failure": attr.string(mandatory = True),
}

def _make_incompatible_runtime_test(scenario):
    return analysistest.make(
        _incompatible_runtime_test_impl,
        attrs = _INCOMPATIBLE_TEST_ATTRS,
        config_settings = {
            str(Label("//:scenario")): scenario,
        },
        expect_failure = True,
    )

magic_mismatch_test = _make_incompatible_runtime_test("magic_mismatch")
missing_exec_magic_test = _make_incompatible_runtime_test("missing_exec_magic")
missing_target_magic_test = _make_incompatible_runtime_test("missing_target_magic")
unbound_exec_identity_test = _make_incompatible_runtime_test("unbound_exec_identity")

def _compatible_runtime_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(
        env,
        ["WhlInstall"],
        [action.mnemonic for action in actions],
        "successful scenario should install one wheel",
    )
    asserts.equals(
        env,
        ctx.attr.expect_compile_pyc,
        "--compile-pyc" in actions[0].argv,
        "WhlInstall compile_pyc argument",
    )
    if ctx.attr.expect_compile_pyc:
        argv = actions[0].argv
        asserts.true(
            env,
            argv[0].endswith("/exec-python"),
            "WhlInstall must execute the exec runtime interpreter",
        )
        asserts.equals(
            env,
            [
                "--compile-pyc",
                "--pyc-invalidation-mode",
                "checked-hash",
                "--python",
                argv[0],
            ],
            argv[-5:],
            "WhlInstall compilation arguments",
        )
    else:
        for arg in ["--compile-pyc", "--pyc-invalidation-mode", "--python"]:
            asserts.false(
                env,
                arg in actions[0].argv,
                "disabled compilation must omit {}".format(arg),
            )
    return analysistest.end(env)

def _make_compatible_runtime_test(scenario, expect_compile_pyc):
    return analysistest.make(
        _compatible_runtime_test_impl,
        attrs = {
            "expect_compile_pyc": attr.bool(default = expect_compile_pyc),
        },
        config_settings = {
            str(Label("//:scenario")): scenario,
        },
    )

compatible_metadata_test = _make_compatible_runtime_test("compatible_metadata", True)
compile_disabled_test = _make_compatible_runtime_test("compile_disabled", False)
exec_runtime_only_test = _make_compatible_runtime_test("exec_runtime_only", True)
ordinary_runtime_pairs_test = _make_compatible_runtime_test("ordinary_runtime_pairs", True)
