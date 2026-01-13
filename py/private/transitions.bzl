"""Common transition implementation used by the various terminals."""

VENV_FLAG = "@aspect_rules_py//uv/private/constraints/venv:venv"
RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"

def _python_transition_impl(settings, attr):
    acc = {}
    if attr.python_version:
        acc[RPY_VERSION_FLAG] = str(attr.python_version)
    else:
        acc[RPY_VERSION_FLAG] = settings[RPY_VERSION_FLAG]

    # Set the venv transition
    if attr.venv:
        acc[VENV_FLAG] = str(attr.venv)
    else:
        acc[VENV_FLAG] = settings[VENV_FLAG]

    return acc

python_transition = transition(
    implementation = _python_transition_impl,
    inputs = [
        RPY_VERSION_FLAG,
        VENV_FLAG,
    ],
    outputs = [
        RPY_VERSION_FLAG,
        VENV_FLAG,
    ],
)

def _bin_to_lib_transition_impl(settings, attr):
    return {
        "//py/private:bin_to_lib_flag": False,
    }

bin_to_lib_transition = transition(
    implementation = _bin_to_lib_transition_impl,
    inputs = [
        "//py/private:bin_to_lib_flag",
    ],
    outputs = [
        "//py/private:bin_to_lib_flag",
    ],
)

# The old name, FIXME: refactor this out
python_version_transition = python_transition
