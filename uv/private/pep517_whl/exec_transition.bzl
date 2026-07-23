load("@aspect_rules_py_uv_host//:defs.bzl", "CURRENT_PLATFORM_LIBC", "CURRENT_PLATFORM_VERSION")

_PLATFORM_LIBC_FLAG = str(Label("@aspect_rules_py//uv/private/constraints/platform:platform_libc"))
_PLATFORM_VERSION_FLAG = str(Label("@aspect_rules_py//uv/private/constraints/platform:platform_version"))

_HOST_OPTION_INPUTS = [
    "//command_line_option:platforms",
    "//command_line_option:host_platform",
    "//command_line_option:host_cpu",
    "//command_line_option:host_compilation_mode",
    "//command_line_option:host_copt",
    "//command_line_option:host_cxxopt",
    "//command_line_option:host_linkopt",
    "//command_line_option:host_action_env",
    "//command_line_option:host_features",
]

_HOST_OPTION_OUTPUTS = [
    "//command_line_option:platforms",
    "//command_line_option:cpu",
    "//command_line_option:compilation_mode",
    "//command_line_option:copt",
    "//command_line_option:cxxopt",
    "//command_line_option:linkopt",
    "//command_line_option:action_env",
    "//command_line_option:features",
]

def _exec_transition_impl(settings, _attr):
    if settings["//command_line_option:platforms"] == [settings["//command_line_option:host_platform"]]:
        return {}

    return {
        "//command_line_option:platforms": [settings["//command_line_option:host_platform"]],
        "//command_line_option:cpu": settings["//command_line_option:host_cpu"],
        "//command_line_option:compilation_mode": settings["//command_line_option:host_compilation_mode"],
        "//command_line_option:copt": settings["//command_line_option:host_copt"],
        "//command_line_option:cxxopt": settings["//command_line_option:host_cxxopt"],
        "//command_line_option:linkopt": settings["//command_line_option:host_linkopt"],
        "//command_line_option:action_env": settings["//command_line_option:host_action_env"],
        "//command_line_option:features": settings["//command_line_option:host_features"],
        _PLATFORM_LIBC_FLAG: CURRENT_PLATFORM_LIBC,
        _PLATFORM_VERSION_FLAG: CURRENT_PLATFORM_VERSION,
    }

exec_transition = transition(
    implementation = _exec_transition_impl,
    inputs = _HOST_OPTION_INPUTS,
    outputs = _HOST_OPTION_OUTPUTS + [
        _PLATFORM_LIBC_FLAG,
        _PLATFORM_VERSION_FLAG,
    ],
)
