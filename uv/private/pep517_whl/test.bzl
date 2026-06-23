"""Analysis tests for the PEP 517 source-build action boundary.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the command and environment wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_ACTION_ENV = "//command_line_option:action_env"
_HOST_PYTHON_ENV = [
    "PYTHONHOME=/host/home",
    "PYTHONPATH=/host/path",
    "PYTHONPLATLIBDIR=host-lib",
    "PYTHONSAFEPATH=1",
]

def _hostile_python_env_transition_impl(settings, _attr):
    names = {entry.split("=", 1)[0]: True for entry in _HOST_PYTHON_ENV}
    action_env = [
        entry
        for entry in settings[_ACTION_ENV]
        if entry.split("=", 1)[0].upper() not in names
    ]
    return {_ACTION_ENV: action_env + _HOST_PYTHON_ENV}

_hostile_python_env_transition = transition(
    implementation = _hostile_python_env_transition_impl,
    inputs = [_ACTION_ENV],
    outputs = [_ACTION_ENV],
)

def _hostile_python_env_target_impl(ctx):
    return [DefaultInfo(files = ctx.attr.target[0][DefaultInfo].files)]

hostile_python_env_target = rule(
    implementation = _hostile_python_env_target_impl,
    attrs = {
        "target": attr.label(
            cfg = _hostile_python_env_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

_FILTERED_NATIVE_ENV_KEYS = [
    "AR",
    "CC",
    "CPP",
    "CXX",
    "LD",
    "LDCXXSHARED",
    "LDSHARED",
    "MPICC",
    "STRIP",
]
_HOST_NATIVE_ENV = [
    "{}=/host/{}".format(key, key.lower())
    for key in _FILTERED_NATIVE_ENV_KEYS
]
_TOOLCHAIN_ENV_KEYS = ["DEFAULT_TOOL", "RUNFILE_TOOL", "ALL_FILES_TOOL"]
_INPUT_ONLY_TOOL = "uv/private/pep517_whl/build_helper_native_tools_test.py"

def _analysis_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

pep517_whl_toolchain_env_failure_test = analysistest.make(
    _analysis_failure_test_impl,
    attrs = {"expected_error": attr.string()},
    expect_failure = True,
)

def _template_variable_tool_impl(ctx):
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = ctx.runfiles(files = ctx.files.runfiles),
        ),
        platform_common.ToolchainInfo(all_files = depset(ctx.files.all_files)),
        platform_common.TemplateVariableInfo(ctx.attr.variables),
    ]

template_variable_tool = rule(
    implementation = _template_variable_tool_impl,
    attrs = {
        "all_files": attr.label_list(allow_files = True),
        "runfiles": attr.label_list(allow_files = True),
        "srcs": attr.label_list(allow_files = True),
        "variables": attr.string_dict(mandatory = True),
    },
)

def _pep517_whl_toolchain_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [action for action in target.actions if action.mnemonic == "PySdistBuild"]
    asserts.equals(env, 1, len(actions), "expected exactly one pure wheel build action")
    if len(actions) != 1:
        return analysistest.end(env)

    action = actions[0]
    inputs = action.inputs.to_list()
    asserts.true(
        env,
        any([f.path == _INPUT_ONLY_TOOL for f in inputs]),
        "DefaultInfo-only build-tool files must be action inputs",
    )
    for key in _TOOLCHAIN_ENV_KEYS:
        tool = action.env.get(key)
        asserts.true(env, tool != None, "{} must be expanded from the toolchain".format(key))
        if tool == None:
            continue
        asserts.false(env, "$({})".format(key) in tool, "{} must be expanded before action execution".format(key))
        asserts.true(
            env,
            any([
                tool == f.path or
                (f.is_directory and tool.startswith(f.path + "/")) or
                f.path.startswith(tool + "/")
                for f in inputs
            ]),
            "expanded {} must be covered by the build action inputs: {}".format(key, tool),
        )
    absolutized_env = [
        action.argv[index + 1]
        for index in range(len(action.argv))
        if action.argv[index] == "--absolutize-toolchain-env"
    ]
    asserts.equals(
        env,
        sorted(_TOOLCHAIN_ENV_KEYS),
        sorted(absolutized_env),
        "whole-value toolchain paths must be repaired after the helper changes cwd",
    )
    asserts.equals(
        env,
        "explicit",
        action.env.get("SOURCE_DATE_EPOCH"),
        "explicit env must override the common build environment",
    )
    return analysistest.end(env)

pep517_whl_toolchain_env_test = analysistest.make(
    _pep517_whl_toolchain_env_test_impl,
)

def _pep517_whl_exec_configuration_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [action for action in target.actions if action.mnemonic == "PySdistBuild"]
    asserts.equals(env, 1, len(actions), "expected exactly one pure wheel build action")
    if len(actions) == 1:
        action = actions[0]
        expected = "uv/private/pep517_whl/build_helper.py"
        asserts.equals(
            env,
            expected,
            action.env.get("BUILD_TOOLCHAIN_PATH"),
            "build_toolchains must use the wheel-build action's execution configuration",
        )
        asserts.true(
            env,
            any([f.path == expected for f in action.inputs.to_list()]),
            "the execution-configured build_toolchains files must be action inputs",
        )
    return analysistest.end(env)

pep517_whl_exec_configuration_test = analysistest.make(
    _pep517_whl_exec_configuration_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("//uv/private/pep517_whl:__cross_target_platform")),
    },
)

def _toolchain_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    build_actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(
        env,
        1,
        len(build_actions),
        "expected exactly one PySdistNativeBuild action",
    )

    if len(build_actions) != 1:
        return analysistest.end(env)

    action = build_actions[0]
    action_env = action.env
    inputs = action.inputs.to_list()
    missing = [key for key in ctx.attr.expected_package_path_env if key not in action_env]
    asserts.equals(
        env,
        [],
        missing,
        "missing package environment keys; got: {}".format(sorted(action_env.keys())),
    )
    for key in ctx.attr.expected_package_path_env:
        tool = action_env.get(key)
        if tool == None:
            continue
        asserts.true(
            env,
            any([
                tool == f.path or
                (f.is_directory and tool.startswith(f.path + "/")) or
                f.path.startswith(tool + "/")
                for f in inputs
            ]),
            "expanded {} must be covered by explicit build_toolchains inputs: {}".format(key, tool),
        )

    absolutized_env = [
        action.argv[index + 1]
        for index in range(len(action.argv))
        if action.argv[index] == "--absolutize-toolchain-env"
    ]
    asserts.equals(
        env,
        sorted(ctx.attr.expected_package_path_env),
        sorted(absolutized_env),
        "only declared whole-value toolchain paths require cwd repair",
    )

    for key in _FILTERED_NATIVE_ENV_KEYS:
        if key in ctx.attr.expected_env:
            continue
        asserts.false(
            env,
            key in action_env,
            "{} must not be inherited or inferred".format(key),
        )

    for key, expected in ctx.attr.expected_env.items():
        asserts.equals(
            env,
            expected,
            action_env.get(key),
            "explicit package env must set {} exactly".format(key),
        )

    return analysistest.end(env)

def _toolchain_env_test_attrs():
    return {
        "expected_env": attr.string_dict(),
        "expected_package_path_env": attr.string_list(),
    }

pep517_native_whl_toolchain_env_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        _ACTION_ENV: _HOST_NATIVE_ENV,
    },
)
