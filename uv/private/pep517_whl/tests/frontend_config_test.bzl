"""Characterization tests for the PEP 517 frontend's configuration.

The `tool` attribute uses `cfg = config.exec(TARGET_EXEC_GROUP)`: the
frontend must build for the execution platform the wheel action runs on.
These tests pin what that means today, through a probe rule that encodes
its observed configuration into its executable's *file name* — the only
channel an analysis test can read, since file contents don't exist at
analysis time and tool runfiles arrive as an opaque middleman.

Two properties are pinned:

- exec configuration: the frontend's executable lives in an `-exec` output
  directory, proving the exec transition applied (a target-configuration
  frontend would break remote execution — the binary must match the worker,
  not the target).
- Starlark flag reset: Bazel does not reset Starlark flags on exec edges,
  so `--//uv/private/constraints/platform:platform_libc` set in the target
  configuration survives into the frontend. The pep517_frontend wrapper
  (frontend.bzl) resets the flag inside the exec configuration; the leak
  test wires the wrapper explicitly and asserts the reset value reaches
  the frontend instead of the target's. Production wiring is the cross
  code path's concern — native builds' leaked flags are already the
  execution platform's.
"""

load("@aspect_rules_py_uv_host//:defs.bzl", "CURRENT_PLATFORM_LIBC")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_PLATFORM_LIBC_FLAG = "//uv/private/constraints/platform:platform_libc"

def _flag_probe_impl(ctx):
    # Tool runfiles reach the action as an opaque middleman, so the only
    # analysis-visible channel is the executable's own file name.
    libc = ctx.attr._platform_libc[BuildSettingInfo].value or "unset"
    exe = ctx.actions.declare_file("{}_saw_libc_{}.sh".format(ctx.label.name, libc))
    ctx.actions.write(exe, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [DefaultInfo(executable = exe, files = depset([exe]))]

flag_probe = rule(
    implementation = _flag_probe_impl,
    doc = "Executable named after the platform_libc value it was configured with.",
    executable = True,
    attrs = {
        "_platform_libc": attr.label(default = Label(_PLATFORM_LIBC_FLAG)),
    },
)

def _build_action(env):
    target = analysistest.target_under_test(env)
    actions = [a for a in target.actions if a.mnemonic == "PySdistBuild"]
    asserts.equals(env, 1, len(actions), "expected exactly one PySdistBuild action")
    return actions[0] if actions else None

def _probe_libc_value(action):
    basename = action.argv[0].split("/")[-1]
    _, sep, value = basename.partition("_saw_libc_")
    return value.removesuffix(".sh") if sep else None

def _frontend_exec_config_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env)
    if action:
        tool_path = action.argv[0]
        asserts.true(
            env,
            "-exec" in tool_path,
            "the frontend must be built in an exec configuration " +
            "(its binary runs on the execution platform); got: " + tool_path,
        )
    return analysistest.end(env)

frontend_exec_config_test = analysistest.make(_frontend_exec_config_test_impl)

def _frontend_libc_leak_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env)
    if action:
        asserts.equals(
            env,
            CURRENT_PLATFORM_LIBC,
            _probe_libc_value(action),
            "the target configuration's platform_libc (musl here) must " +
            "not leak into the frontend: pep517_frontend resets the flag " +
            "to the host's value inside the exec configuration",
        )
    return analysistest.end(env)

frontend_libc_leak_test = analysistest.make(
    _frontend_libc_leak_test_impl,
    config_settings = {
        "@@//uv/private/constraints/platform:platform_libc": "musl",
    },
)

def _frontend_probe_plumbing_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env)
    if action:
        asserts.true(
            env,
            _probe_libc_value(action) != None,
            "the probe's flag value must be readable from the frontend's " +
            "executable path; without it the leak test can pass vacuously",
        )
    return analysistest.end(env)

frontend_probe_plumbing_test = analysistest.make(_frontend_probe_plumbing_test_impl)

def _frontend_libc_override_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _build_action(env)
    if action:
        asserts.equals(
            env,
            "musl",
            _probe_libc_value(action),
            "an explicit libc on pep517_frontend must reach the frontend's " +
            "configuration: it is the escape hatch for execution platforms " +
            "whose libc differs from the host probe's",
        )
    return analysistest.end(env)

frontend_libc_override_test = analysistest.make(_frontend_libc_override_test_impl)
