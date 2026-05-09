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
