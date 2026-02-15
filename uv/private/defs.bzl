"Internal helpers."

load("@with_cfg.bzl", "with_cfg")
load("//py:defs.bzl", "py_library")

LIB_MODE = "//uv/private/constraints:lib_mode"

py_whl_library, _ = with_cfg(py_library).set(Label(LIB_MODE), "whl").build()

def _lib_mode_transition_impl(settings, attr):
    return {LIB_MODE: "lib"}

lib_mode_transition = transition(
    implementation = _lib_mode_transition_impl,
    inputs = [],
    outputs = [LIB_MODE],
)

def _whl_mode_transition_impl(settings, attr):
    return {LIB_MODE: "whl"}

whl_mode_transition = transition(
    implementation = _whl_mode_transition_impl,
    inputs = [],
    outputs = [LIB_MODE],
)

def _whl_requirements_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [s.files for s in ctx.attr.srcs]))]

whl_requirements = rule(
    implementation = _whl_requirements_impl,
    attrs = {
        "srcs": attr.label_list(cfg = whl_mode_transition),
    },
)
