"""Analysis tests: pep517_native_whl forwards toolchain make-variables
into the PySdistNativeBuild action env.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the env wiring.
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

# CC and CXX default to the resolved C++ toolchain compiler. The other values
# come from its TemplateVariableInfo. SYSROOT is omitted because some
# toolchains legitimately have an empty sysroot and do not expose it as a
# make variable today.
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

    # CC and CXX both default to the compiler discovered from the resolved C++
    # toolchain. If the defaults diverge in the future, relax this assertion.
    asserts.equals(
        env,
        action_env.get("CC"),
        action_env.get("CXX"),
        "CC and CXX should point at the same compiler driver",
    )

    # JAR is constructed from $(JAVABASE)/bin/jar — sanity-check the suffix.
    asserts.true(
        env,
        action_env.get("JAR", "").endswith("/bin/jar"),
        "JAR should resolve under JAVA_HOME/bin/jar; got {}".format(action_env.get("JAR")),
    )

    return analysistest.end(env)

pep517_native_whl_toolchain_env_test = analysistest.make(_toolchain_env_test_impl)

def _compiler_env_override_test_impl(ctx):
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
    asserts.true(
        env,
        action_env.get("CC", "").endswith(" -DEXPLICIT_CC=1"),
        "explicit CC command was overwritten: {}".format(action_env.get("CC")),
    )
    asserts.true(
        env,
        action_env.get("CXX", "").endswith(" -DEXPLICIT_CXX=1"),
        "explicit CXX command was overwritten: {}".format(action_env.get("CXX")),
    )

    return analysistest.end(env)

pep517_native_whl_compiler_env_override_test = analysistest.make(_compiler_env_override_test_impl)
