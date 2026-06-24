"""Common transition implementation used by the various terminals."""

DEP_GROUP_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group"

# Shared with rules_python so every Python rule observes one version setting.
PYTHON_VERSION_FLAG = "@rules_python//python/config_settings:python_version"

# Interpreter feature flags that must be propagated through transitions.
_FREETHREADED_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"

def _python_transition_impl(settings, attr):
    acc = {}
    if attr.python_version:
        version = str(attr.python_version)
    else:
        version = settings[PYTHON_VERSION_FLAG]

    acc[PYTHON_VERSION_FLAG] = version

    # Set the dep_group transition. The attr is only present on `py_venv`
    # (rules without it propagate the inherited setting; `py_venv_exec`
    # is config-agnostic — its runfiles inherit the venv's wheels at
    # whatever DEP_GROUP_FLAG the venv resolved under).
    dep_group = getattr(attr, "dep_group", None)
    if dep_group:
        acc[DEP_GROUP_FLAG] = str(dep_group)
    else:
        acc[DEP_GROUP_FLAG] = settings[DEP_GROUP_FLAG]

    # Propagate interpreter feature flags
    acc[_FREETHREADED_FLAG] = settings[_FREETHREADED_FLAG]

    return acc

python_transition = transition(
    implementation = _python_transition_impl,
    inputs = [
        PYTHON_VERSION_FLAG,
        DEP_GROUP_FLAG,
        _FREETHREADED_FLAG,
    ],
    outputs = [
        PYTHON_VERSION_FLAG,
        DEP_GROUP_FLAG,
        _FREETHREADED_FLAG,
    ],
)

# The old name, FIXME: refactor this out
python_version_transition = python_transition
