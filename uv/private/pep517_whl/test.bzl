"""Analysis tests for the pep517_native_whl toolchain boundary.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the command and environment wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "action_config",
    "tool",
    "tool_path",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

_ACTION_ENV = "//command_line_option:action_env"
_HOST_ENV = [
    "PYTHONHOME=/host/home",
    "PYTHONPATH=/host/path",
    "PYTHONPLATLIBDIR=host-lib",
    "PYTHONSAFEPATH=1",
    "RUNFILES_MANIFEST_ONLY=1",
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

# Env vars sourced from the C++ toolchain's TemplateVariableInfo. SYSROOT is
# omitted because some toolchains legitimately have an empty sysroot and it
# isn't exposed as a TemplateVariableInfo make variable today.
_CC_ENV_KEYS = ["AR", "LD", "STRIP"]
_COMPILER_COMMAND_KEYS = ["CC", "CXX"]

# Env vars sourced from the Java runtime toolchain's TemplateVariableInfo.
_JDK_ENV_KEYS = ["JAVA_HOME", "JAVA", "JAR"]

_REQUIRED_ENV_KEYS = _CC_ENV_KEYS + _JDK_ENV_KEYS

# A C++ toolchain whose C and C++ compile actions deliberately share one
# driver executable. `compiler` controls the driver-mode heuristic in
# pep517_native_whl: "clang" must select the C++ driver mode for C++ targets,
# while "gcc" (and any other shared driver) must not.
def _same_driver_toolchain_config_impl(ctx):
    driver = ctx.executable.driver.basename
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        abi_libc_version = "unknown",
        abi_version = "unknown",
        action_configs = [
            action_config(
                action_name = action_name,
                enabled = True,
                tools = [tool(path = driver)],
            )
            for action_name in (
                ACTION_NAMES.c_compile,
                ACTION_NAMES.cpp_compile,
            )
        ],
        compiler = ctx.attr.compiler,
        host_system_name = "local",
        target_cpu = "test",
        target_libc = "unknown",
        target_system_name = "local",
        tool_paths = [
            tool_path(name = name, path = driver)
            for name in (
                "ar",
                "cpp",
                "gcc",
                "gcov",
                "ld",
                "nm",
                "objdump",
                "strip",
            )
        ],
        toolchain_identifier = "same-driver-{}-test".format(ctx.attr.compiler),
    )

same_driver_toolchain_config = rule(
    implementation = _same_driver_toolchain_config_impl,
    attrs = {
        "compiler": attr.string(mandatory = True),
        "driver": attr.label(
            cfg = "exec",
            allow_files = True,
            executable = True,
            mandatory = True,
        ),
    },
    provides = [CcToolchainConfigInfo],
)

def _declares_path(inputs, candidate):
    for file in inputs:
        if file.path == candidate:
            return True
        if file.path.startswith(candidate + "/"):
            return True

        # is_directory reflects ctx.actions.declare_directory(), not the
        # filesystem type of source inputs such as repository directories:
        # https://bazel.build/rules/lib/builtins/File#is_directory
        if candidate.startswith(file.path + "/"):
            return True
    return False

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

    action = build_actions[0]
    action_env = action.env
    missing = [k for k in _REQUIRED_ENV_KEYS if k not in action_env]
    asserts.equals(
        env,
        [],
        missing,
        "missing env keys on action; got: {}".format(sorted(action_env.keys())),
    )
    for key in _REQUIRED_ENV_KEYS:
        asserts.true(
            env,
            action_env.get(key),
            "${} should resolve to a non-empty value".format(key),
        )

    command_arg_indexes = [
        i
        for i in range(len(action.argv))
        if action.argv[i] == "--compiler-config"
    ]
    asserts.equals(env, 1, len(command_arg_indexes))
    compiler_config = json.decode(action.argv[command_arg_indexes[0] + 1])
    commands = compiler_config["commands"]
    environments = compiler_config["environments"]
    inputs = action.inputs.to_list()
    for key in _COMPILER_COMMAND_KEYS:
        asserts.true(env, key in environments, "missing configured {} environment".format(key))
        command = commands.get(key, [])
        asserts.true(env, command, "missing configured {} command".format(key))
        if command:
            asserts.true(
                env,
                _declares_path(inputs, command[0]),
                "configured {} executable must be a declared action input; got {}".format(
                    key,
                    command[0],
                ),
            )

    if ctx.attr.expect_same_driver:
        asserts.equals(
            env,
            commands["CC"][0],
            commands["CXX"][0],
            "fixture must use one executable for C and C++",
        )
        if ctx.attr.expect_driver_mode_flag:
            asserts.true(
                env,
                "--driver-mode=g++" in commands["CXX"],
                "shared Clang driver must select the C++ driver mode",
            )
        else:
            asserts.false(
                env,
                "--driver-mode=g++" in commands["CXX"],
                "non-Clang shared driver must not receive Clang driver-mode flags",
            )

    for input_root in compiler_config["input_roots"]:
        asserts.true(
            env,
            _declares_path(inputs, input_root),
            "compiler input root must be a declared action input; got {}".format(
                input_root,
            ),
        )

    for key, expected in ctx.attr.expected_env.items():
        asserts.equals(
            env,
            expected,
            action_env.get(key),
            "explicit {} should replace the toolchain default".format(key),
        )

    # JAR is constructed from $(JAVABASE)/bin/jar — sanity-check the suffix.
    asserts.true(
        env,
        action_env.get("JAR", "").endswith("/bin/jar"),
        "JAR should resolve under JAVA_HOME/bin/jar; got {}".format(action_env.get("JAR")),
    )

    return analysistest.end(env)

def _toolchain_env_test_attrs():
    return {
        "expected_env": attr.string_dict(),
        "expect_driver_mode_flag": attr.bool(),
        "expect_same_driver": attr.bool(),
    }

pep517_native_whl_toolchain_env_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
)

pep517_native_whl_same_driver_gcc_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__same_driver_gcc_toolchain",
        ],
    },
)

pep517_native_whl_same_driver_clang_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__same_driver_clang_toolchain",
        ],
    },
)
