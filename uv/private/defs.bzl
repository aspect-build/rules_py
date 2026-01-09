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
