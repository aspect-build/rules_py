"""Analysis tests: pep517_native_whl forwards toolchain make-variables
into the PySdistNativeBuild action env.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the env wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

# Env vars sourced from the CC toolchain's TemplateVariableInfo. SYSROOT is
# omitted because some toolchains legitimately have an empty sysroot and
# it isn't exposed as a TemplateVariableInfo make variable today.
_CC_ENV_KEYS = ["CC", "CXX", "AR", "LD", "STRIP"]

# Env vars sourced from the Java runtime toolchain's TemplateVariableInfo.
_JDK_ENV_KEYS = ["JAVA_HOME", "JAVA", "JAR"]

_REQUIRED_ENV_KEYS = _CC_ENV_KEYS + _JDK_ENV_KEYS

def _analysis_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

build_memory_failure_test = analysistest.make(
    _analysis_failure_test_impl,
    attrs = {"expected_error": attr.string()},
    expect_failure = True,
)

def _build_memory_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [action for action in target.actions if action.mnemonic == "PySdistBuild"]
    asserts.equals(env, 1, len(actions))
    return analysistest.end(env)

build_memory_test = analysistest.make(_build_memory_test_impl)

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

    # CC and CXX both derive from cc_toolchain's $(CC) make variable today.
    # If we ever switch CXX to a c++ compile driver (e.g. via a custom
    # TemplateVariableInfo shim), this assertion can be relaxed.
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
