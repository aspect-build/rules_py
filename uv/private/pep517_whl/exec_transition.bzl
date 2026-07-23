load("@aspect_rules_py_uv_host//:defs.bzl", "CURRENT_PLATFORM_LIBC", "CURRENT_PLATFORM_VERSION")

_PLATFORM_LIBC_FLAG = str(Label("@aspect_rules_py//uv/private/constraints/platform:platform_libc"))
_PLATFORM_VERSION_FLAG = str(Label("@aspect_rules_py//uv/private/constraints/platform:platform_version"))

_INPUTS = [
    "//command_line_option:platforms",
    "//command_line_option:host_platform",
    _PLATFORM_LIBC_FLAG,
    _PLATFORM_VERSION_FLAG,
]

_OUTPUTS = [
    "//command_line_option:platforms",
    _PLATFORM_LIBC_FLAG,
    _PLATFORM_VERSION_FLAG,
]

def _exec_transition_impl(settings, _attr):
    if settings["//command_line_option:platforms"] == [settings["//command_line_option:host_platform"]] and \
       settings[_PLATFORM_LIBC_FLAG] == CURRENT_PLATFORM_LIBC and \
       settings[_PLATFORM_VERSION_FLAG] == CURRENT_PLATFORM_VERSION:
        return {}
    return {
        "//command_line_option:platforms": [settings["//command_line_option:host_platform"]],
        _PLATFORM_LIBC_FLAG: CURRENT_PLATFORM_LIBC,
        _PLATFORM_VERSION_FLAG: CURRENT_PLATFORM_VERSION,
    }

exec_transition = transition(
    implementation = _exec_transition_impl,
    inputs = _INPUTS,
    outputs = _OUTPUTS,
)
