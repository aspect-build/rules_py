"""Common transition implementation used by the various terminals."""

VENV_FLAG = "@aspect_rules_py//uv/private/constraints/venv:venv"

# Our own python_version flag, replacing the rules_python one.
PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"

# rules_python's flag, kept for backward compatibility during migration.
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"

# Interpreter feature flags that must be propagated through transitions.
_FREETHREADED_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"

# Public alias for backward compatibility
RPY_VERSION_FLAG = _RPY_VERSION_FLAG

def _python_transition_impl(settings, attr):
    acc = {}
    if attr.python_version:
        version = str(attr.python_version)
    else:
        version = settings[PYTHON_VERSION_FLAG] or settings[_RPY_VERSION_FLAG]

    acc[PYTHON_VERSION_FLAG] = version
    acc[_RPY_VERSION_FLAG] = version

    # Set the venv transition
    if attr.venv:
        acc[VENV_FLAG] = str(attr.venv)
    else:
        acc[VENV_FLAG] = settings[VENV_FLAG]

    # Propagate interpreter feature flags
    acc[_FREETHREADED_FLAG] = settings[_FREETHREADED_FLAG]

    return acc

python_transition = transition(
    implementation = _python_transition_impl,
    inputs = [
        PYTHON_VERSION_FLAG,
        _RPY_VERSION_FLAG,
        VENV_FLAG,
        _FREETHREADED_FLAG,
    ],
    outputs = [
        PYTHON_VERSION_FLAG,
        _RPY_VERSION_FLAG,
        VENV_FLAG,
        _FREETHREADED_FLAG,
    ],
)

# The old name, FIXME: refactor this out
python_version_transition = python_transition
