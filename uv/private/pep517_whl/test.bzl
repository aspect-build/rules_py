"""Analysis tests: pep517_native_whl forwards toolchain make-variables
into the PySdistNativeBuild action env.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the env wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//uv/private/pep517_whl:compiler.bzl", "compiler_driver_paths")

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

# Env vars sourced from the CC toolchain's TemplateVariableInfo. SYSROOT is
# omitted because some toolchains legitimately have an empty sysroot and
# it isn't exposed as a TemplateVariableInfo make variable today.
_CC_ENV_KEYS = ["CC", "CXX", "AR", "LD", "STRIP"]

# Env vars sourced from the Java runtime toolchain's TemplateVariableInfo.
_JDK_ENV_KEYS = ["JAVA_HOME", "JAVA", "JAR"]

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

    action_inputs = [f.path for f in build_actions[0].inputs.to_list()]
    asserts.true(
        env,
        action_env.get("CXX") in action_inputs,
        "CXX should come from the selected toolchain inputs",
    )
    cc = action_env.get("CC")
    driver_paths = compiler_driver_paths(cc, {path: True for path in action_inputs})
    asserts.equals(
        env,
        driver_paths.cxx if driver_paths else cc,
        action_env.get("CXX"),
        "CXX should use the declared companion or selected compiler fallback",
    )

    # JAR is constructed from $(JAVABASE)/bin/jar — sanity-check the suffix.
    asserts.true(
        env,
        action_env.get("JAR", "").endswith("/bin/jar"),
        "JAR should resolve under JAVA_HOME/bin/jar; got {}".format(action_env.get("JAR")),
    )

    return analysistest.end(env)

pep517_native_whl_toolchain_env_test = analysistest.make(_toolchain_env_test_impl)

def _compiler_driver_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    exact = compiler_driver_paths("gcc", {"gcc": True, "g++": True})
    asserts.equals(env, "g++", exact.cxx)

    versioned = compiler_driver_paths(
        "toolchain/bin/clang-22",
        {
            "toolchain/bin/clang-22": True,
            "toolchain/bin/clang++-22": True,
        },
    )
    asserts.equals(env, "toolchain/bin/clang++-22", versioned.cxx)

    for near_miss in ["clang-cl", "clang-format", "gcc-ar"]:
        asserts.equals(
            env,
            None,
            compiler_driver_paths(near_miss, {near_miss: True}),
            "{} should not be treated as a compiler driver".format(near_miss),
        )

    fallback = compiler_driver_paths("toolchain/bin/gcc", {"toolchain/bin/gcc": True})
    asserts.equals(env, "toolchain/bin/gcc", fallback.cxx)
    return unittest.end(env)

compiler_driver_paths_test = unittest.make(_compiler_driver_paths_test_impl)

def compiler_driver_test_suite(name):
    unittest.suite(name, compiler_driver_paths_test)
