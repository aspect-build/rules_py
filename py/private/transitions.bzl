"""Common transition implementation used by the various terminals."""

VENV_FLAG = "@aspect_rules_py//pip/private/constraints/venv:venv"
VERSION_FLAG = "@rules_python//python/config_settings:python_version"

def _python_transition_impl(settings, attr):
    acc = {}
    if attr.python_version:
        acc[VERSION_FLAG] = str(attr.python_version)
    else:
        acc[VERSION_FLAG] = settings[VERSION_FLAG]
        
    acc[VENV_FLAG] = settings.get(VENV_FLAG) or str(attr.venv)

    print(acc)
        
    return acc

python_transition = transition(
    implementation = _python_transition_impl,
    inputs = [
        VERSION_FLAG,
        VENV_FLAG,
    ],
    outputs = [
        VERSION_FLAG,
        VENV_FLAG,
    ],
)

# The old name, FIXME: refactor this out
python_version_transition = python_transition
