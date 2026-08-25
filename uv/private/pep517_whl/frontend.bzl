"""Re-configures a cross build's PEP 517 frontend for the host it runs on.

The wheel rules reach their `tool` through `cfg = config.exec(...)`, which
moves `--platforms` to the selected execution platform but leaves Starlark
flags untouched: the target configuration's `platform_libc` and
`platform_version` keep flowing into the frontend. For a *native* build
(exec == target — the only mode the rules allow today) those flags are
already the execution platform's and nothing needs fixing. For a *cross*
build the frontend runs on the host while the flags describe the foreign
target, so its own Python build dependencies get selected with the wrong
platform identity (see `frontend_libc_leak_test`).

Bazel offers no way to chain a Starlark transition after `config.exec` on
one attribute, so the reset takes an intermediate target: `pep517_frontend`
wraps the real frontend, applies a self-transition inside the already-exec
configuration that resets both flags to the host's values, and forwards
the wrapped executable and its runfiles.

Nothing wires this wrapper up yet: it belongs on the cross code path only,
where "host" is exactly where the frontend executes. Wrapping native
builds would be wrong under remote execution — their leaked target flags
match the worker by definition, while the host-probe constants used here
describe the client.

The reset values default to the host probe's, which is exact when the
execution platform is the host and an approximation otherwise: no
analysis-time source of truth exists for a foreign worker's libc or
version (that is why these are flags, not constraints). The `libc` and
`platform_version` attributes are the escape hatch — a cross wiring that
knows its execution fleet can declare the worker's values instead of
inheriting the client's.
"""

load("@aspect_rules_py_uv_host//:defs.bzl", "CURRENT_PLATFORM_LIBC", "CURRENT_PLATFORM_VERSION")

_PLATFORM_LIBC_FLAG = str(Label("//uv/private/constraints/platform:platform_libc"))
_PLATFORM_VERSION_FLAG = str(Label("//uv/private/constraints/platform:platform_version"))

def _reset_platform_flags_impl(settings, attr):
    if settings[_PLATFORM_LIBC_FLAG] == attr.libc and \
       settings[_PLATFORM_VERSION_FLAG] == attr.platform_version:
        return {}
    return {
        _PLATFORM_LIBC_FLAG: attr.libc,
        _PLATFORM_VERSION_FLAG: attr.platform_version,
    }

_reset_platform_flags = transition(
    implementation = _reset_platform_flags_impl,
    inputs = [_PLATFORM_LIBC_FLAG, _PLATFORM_VERSION_FLAG],
    outputs = [_PLATFORM_LIBC_FLAG, _PLATFORM_VERSION_FLAG],
)

def _pep517_frontend_impl(ctx):
    info = ctx.attr.actual[DefaultInfo]
    inner = info.files_to_run.executable

    # Keep the inner basename: launchers may resolve resources off argv[0],
    # and analysis tests read probe identities from it. The extra directory
    # level keeps the symlink's runfiles tree (<exe>.runfiles) private to
    # this wrapper.
    executable = ctx.actions.declare_file("{}/{}".format(ctx.label.name, inner.basename))
    ctx.actions.symlink(output = executable, target_file = inner, is_executable = True)

    runfiles = ctx.runfiles(files = [inner])
    if info.default_runfiles:
        runfiles = runfiles.merge(info.default_runfiles)
    return [DefaultInfo(
        executable = executable,
        files = depset([executable]),
        runfiles = runfiles,
    )]

pep517_frontend = rule(
    implementation = _pep517_frontend_impl,
    cfg = _reset_platform_flags,
    doc = "Forwards an executable PEP 517 frontend with the platform_libc/platform_version flags reset to the host's values.",
    executable = True,
    attrs = {
        "actual": attr.label(
            cfg = "target",
            doc = "The real frontend binary; configured with this wrapper's (reset) configuration.",
            executable = True,
            mandatory = True,
        ),
        "libc": attr.string(
            default = CURRENT_PLATFORM_LIBC,
            doc = "platform_libc value the frontend is configured with. Defaults to the " +
                  "host's; override when the execution platform's libc is known to differ " +
                  "(e.g. a heterogeneous remote fleet).",
        ),
        "platform_version": attr.string(
            default = CURRENT_PLATFORM_VERSION,
            doc = "platform_version value the frontend is configured with. Defaults to " +
                  "the host's; override alongside `libc` for foreign execution platforms.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
