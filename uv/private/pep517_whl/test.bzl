"""Analysis tests for the PEP 517 source-build action boundary."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_ACTION_ENV = "//command_line_option:action_env"
_HOST_ENV = [
    "PYTHONHOME=/host/home",
    "PYTHONPATH=/host/path",
    "PYTHONPLATLIBDIR=host-lib",
    "PYTHONSAFEPATH=1",
    "RUNFILES_MANIFEST_ONLY=1",
]
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

def _hostile_env_transition_impl(settings, _attr):
    names = {entry.split("=", 1)[0]: True for entry in _HOST_ENV}
    action_env = [
        entry
        for entry in settings[_ACTION_ENV]
        if entry.split("=", 1)[0].upper() not in names
    ]
    return {_ACTION_ENV: action_env + _HOST_ENV}

_hostile_env_transition = transition(
    implementation = _hostile_env_transition_impl,
    inputs = [_ACTION_ENV],
    outputs = [_ACTION_ENV],
)

def _hostile_python_env_target_impl(ctx):
    return [DefaultInfo(files = ctx.attr.target[0][DefaultInfo].files)]

hostile_python_env_target = rule(
    implementation = _hostile_python_env_target_impl,
    attrs = {
        "target": attr.label(
            cfg = _hostile_env_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
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

def _build_action(env, mnemonic):
    target = analysistest.target_under_test(env)
    actions = [action for action in target.actions if action.mnemonic == mnemonic]
    asserts.equals(env, 1, len(actions), "expected exactly one {} action".format(mnemonic))
    return actions[0] if len(actions) == 1 else None

def _absolutized_env(action):
    return [
        action.argv[index + 1]
        for index in range(len(action.argv))
        if action.argv[index] == "--absolutize-env"
    ]

def _assert_action_contract(env, action):
    asserts.equals(
        env,
        "whl",
        action.outputs.to_list()[0].basename,
        "the wheel output directory must remain named whl",
    )
    asserts.equals(env, "uv/private", action.env.get("MODE"), "exact scalar expansion must stay opaque")
    asserts.equals(
        env,
        "run uv/private/pep517_whl/build_helper.py --mode=uv/private",
        action.env.get("COMMAND"),
        "composite command expansion must stay opaque",
    )
    asserts.false(env, "MODE" in _absolutized_env(action), "scalar values are not paths")
    asserts.false(env, "COMMAND" in _absolutized_env(action), "composite commands are not paths")
    asserts.equals(
        env,
        "uv/private/pep517_whl/build_helper.py",
        action.env.get("OPAQUE_PATH"),
        "even exact path expansions in env must stay opaque",
    )
    asserts.false(env, "OPAQUE_PATH" in _absolutized_env(action), "env never implies path semantics")

def _pure_build_tool_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env, "PySdistBuild")
    if action == None:
        return analysistest.end(env)

    asserts.false(env, "--configure-compiler" in action.argv, "pure builds must not infer compiler commands")
    inputs = {f.path: True for f in action.inputs.to_list()}
    asserts.true(
        env,
        any([path.startswith("uv/private/") for path in inputs]),
        "MODE=uv/private must overlap a declared input prefix so the test proves opaque env is not classified from lexical path overlap",
    )
    expected_paths = {
        "DEFAULT_TOOL": "uv/private/pep517_whl/build_helper.py",
        "RUNFILE_TOOL": "uv/private/pep517_whl/tests/python_env_backend/pyproject.toml",
        "ALL_FILES_TOOL": "uv/private/pep517_whl/tests/python_env_backend/backend.py",
    }
    for key, expected in expected_paths.items():
        asserts.equals(env, expected, action.env.get(key), "{} must expand from TemplateVariableInfo".format(key))
        asserts.true(env, expected in inputs, "{} must be a declared action input".format(key))
    direct_tool = action.env.get("DIRECT_TOOL", "")
    asserts.true(
        env,
        direct_tool.endswith("uv/private/pep517_whl/__stub_tool.sh"),
        "build_tool_env must assign the exec-configured target path",
    )
    asserts.true(env, direct_tool in inputs, "the build_tool_env target must be a declared action input")
    asserts.equals(
        env,
        "uv/private/pep517_whl",
        action.env.get("TOOL_DIR"),
        "an ancestor directory materialized by a declared file must be accepted",
    )
    asserts.equals(
        env,
        sorted(expected_paths.keys() + ["DIRECT_TOOL", "TOOL_DIR"]),
        sorted(_absolutized_env(action)),
        "only explicitly declared path_env values may be repaired after the cwd change",
    )
    asserts.equals(
        env,
        "explicit",
        action.env.get("SOURCE_DATE_EPOCH"),
        "explicit package env must override common env",
    )
    _assert_action_contract(env, action)
    return analysistest.end(env)

pep517_whl_build_tool_env_test = analysistest.make(_pure_build_tool_env_test_impl)

def _native_build_tool_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env, "PySdistNativeBuild")
    if action == None:
        return analysistest.end(env)

    _assert_action_contract(env, action)
    asserts.equals(env, ["DEFAULT_TOOL"], _absolutized_env(action), "native builds must repair declared exact paths")
    asserts.equals(env, "explicit-cc --flag", action.env.get("CC"), "explicit env must override filtered ambient env")
    cxx = action.env.get("CXX", "")
    asserts.true(env, bool(cxx), "native builds must infer CXX from the configured C++ toolchain")
    asserts.false(env, cxx.startswith("/host/"), "native CXX must not inherit the host action environment")
    asserts.true(
        env,
        any([f.path == cxx for f in action.inputs.to_list()]),
        "the inferred CXX must be a declared action input",
    )
    toolchain_tool = action.env.get("NATIVE_TOOLCHAIN_TOOL", "")
    asserts.equals(
        env,
        "uv/private/pep517_whl/tests/python_env_backend/backend.py",
        toolchain_tool,
        "common toolchains must still provide Make variables",
    )
    asserts.true(
        env,
        any([f.path == toolchain_tool for f in action.inputs.to_list()]),
        "common toolchain files must remain action inputs",
    )
    asserts.true(env, "--configure-compiler" in action.argv, "native builds must configure compiler wrappers")
    for key in _FILTERED_NATIVE_ENV_KEYS:
        if key not in ["CC", "CXX"]:
            asserts.false(env, key in action.env, "ambient {} must be filtered".format(key))
    return analysistest.end(env)

pep517_native_whl_build_tool_env_test = analysistest.make(
    _native_build_tool_env_test_impl,
    config_settings = {
        _ACTION_ENV: _HOST_NATIVE_ENV,
    },
)

def _analysis_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

pep517_whl_build_tool_env_failure_test = analysistest.make(
    _analysis_failure_test_impl,
    attrs = {"expected_error": attr.string()},
    expect_failure = True,
)

def _build_tool_exec_configuration_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env, "PySdistBuild")
    if action == None:
        return analysistest.end(env)

    expected_tool = "uv/private/pep517_whl/build_helper.py"
    asserts.equals(
        env,
        expected_tool,
        action.env.get("BUILD_TOOL_PATH"),
        "build_tools must be analyzed in an execution configuration",
    )
    asserts.true(
        env,
        any([f.path == expected_tool for f in action.inputs.to_list()]),
        "the execution-configured build tool must be an action input",
    )
    return analysistest.end(env)

pep517_whl_build_tool_exec_configuration_test = analysistest.make(
    _build_tool_exec_configuration_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("//uv/private/pep517_whl:__cross_target_platform")),
    },
)
