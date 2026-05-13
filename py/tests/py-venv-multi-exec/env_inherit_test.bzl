"""Analysis-time test: env_inherit on a py_venv merges with env_inherit on
a py_venv_exec_test consumer (extends, doesn't replace).

A runtime test can't validate this without `bazel test --test_env=...`
setup, since `bazel test` scrubs user-shell env vars and only consults
`RunEnvironmentInfo.inherited_environment` to decide what to forward.
Inspecting the provider directly at analysis time gets us the same
invariant without depending on the test runner's env handling.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _env_inherit_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    inherited = list(target[RunEnvironmentInfo].inherited_environment)
    asserts.equals(
        env,
        ["VAR_FROM_VENV", "VAR_FROM_EXEC"],
        inherited,
        "consumer env_inherit should extend the venv's list, not replace",
    )
    return analysistest.end(env)

env_inherit_test = analysistest.make(_env_inherit_test_impl)

def _contextual_keys_not_inherited_impl(ctx):
    """Per Bazel's RunEnvironmentInfo docs, a name listed in
    `inherited_environment` is shadowed by the caller's shell value when
    set, overriding any matching entry in `environment`. The launcher
    rule must strip the Bazel-contextual identifiers (BAZEL_TARGET,
    BAZEL_WORKSPACE, BAZEL_TARGET_NAME) from `inherited_environment`
    even when the user explicitly puts them in `env_inherit`, so a
    stray `BAZEL_TARGET=...` in the parent shell can't corrupt the
    contextual label seen by the test process.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    run_env = target[RunEnvironmentInfo]
    inherited = list(run_env.inherited_environment)
    asserts.equals(
        env,
        ["VAR_FROM_VENV", "UNRELATED_INHERIT"],
        inherited,
        "BAZEL_* contextual keys must be stripped from inherited_environment; other inherited names must survive",
    )

    # And confirm the contextual values are still in `environment` so
    # the test process sees the right label when the shell is clean.
    environment = run_env.environment
    asserts.equals(
        env,
        "//py/tests/py-venv-multi-exec:_env_inherit_contextual_inner",
        environment.get("BAZEL_TARGET"),
    )
    asserts.equals(
        env,
        "_env_inherit_contextual_inner",
        environment.get("BAZEL_TARGET_NAME"),
    )
    return analysistest.end(env)

contextual_keys_not_inherited_test = analysistest.make(
    _contextual_keys_not_inherited_impl,
)
