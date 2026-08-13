"""Analysis tests: pep517_native_whl forwards toolchain make-variables
into the PySdistNativeBuild action env.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the env wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//uv/private:source_built_wheel.bzl", "SourceBuiltWheelInfo")

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

# Env vars selected from the configured C++ action tools. SYSROOT is omitted
# because some toolchains legitimately have an empty sysroot.
_CC_ENV_KEYS = ["CC", "CXX", "AR", "LD", "STRIP"]

# Env vars sourced from the Java runtime toolchain's TemplateVariableInfo.
_JDK_ENV_KEYS = ["JAVA_HOME", "JAVA"]

_REQUIRED_ENV_KEYS = _CC_ENV_KEYS + _JDK_ENV_KEYS

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

    action_env = build_actions[0].env
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
            "${} should resolve to a non-empty toolchain path".format(key),
        )

    args = build_actions[0].argv
    marker_index = args.index("--execroot-marker")
    marker = args[marker_index + 1]
    asserts.equals(env, "-I{}/relative/include".format(marker), action_env.get("CPPFLAGS"))
    asserts.equals(env, "{}/relative/libdep.a".format(marker), action_env.get("LDFLAGS"))

    action_inputs = [f.path for f in build_actions[0].inputs.to_list()]
    for key in _CC_ENV_KEYS:
        asserts.true(
            env,
            action_env.get(key) in action_inputs,
            "{} should select a declared C++ action tool".format(key),
        )

    return analysistest.end(env)

pep517_native_whl_toolchain_env_test = analysistest.make(_toolchain_env_test_impl)

def _console_scripts_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, SourceBuiltWheelInfo in target, "source-built wheel metadata is absent")
    asserts.equals(
        env,
        tuple(ctx.attr.expected_console_scripts),
        target[SourceBuiltWheelInfo].console_scripts,
    )
    return analysistest.end(env)

pep517_whl_console_scripts_test = analysistest.make(
    _console_scripts_test_impl,
    attrs = {"expected_console_scripts": attr.string_list()},
)

def _execroot_collision_toolchain_impl(_ctx):
    return [platform_common.TemplateVariableInfo({"EXECROOT": "collision"})]

execroot_collision_toolchain = rule(implementation = _execroot_collision_toolchain_impl)

def _execroot_collision_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "exports the reserved `EXECROOT` make-variable")
    return analysistest.end(env)

pep517_native_whl_execroot_collision_test = analysistest.make(
    _execroot_collision_test_impl,
    expect_failure = True,
)
