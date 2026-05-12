"""Analysis tests: pep517_native_whl sets the expected toolchain env vars
on its PySdistNativeBuild action.

Inspecting the action at analysis time avoids needing to actually run a PEP
517 build to verify the env wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

# Env vars that must always be present when a cc_toolchain resolves. SYSROOT
# is omitted because some toolchains legitimately have an empty sysroot.
_REQUIRED_ENV_KEYS = ["CC", "CXX", "AR", "LD", "STRIP"]

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

    # CC and CXX both derive from cc_toolchain.compiler_executable today.
    # If we ever switch CXX to cc_common.get_tool_for_action(cpp_compile),
    # this assertion can be relaxed.
    asserts.equals(
        env,
        action_env.get("CC"),
        action_env.get("CXX"),
        "CC and CXX should point at the same compiler driver",
    )

    return analysistest.end(env)

pep517_native_whl_toolchain_env_test = analysistest.make(_toolchain_env_test_impl)
