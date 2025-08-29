"""Common transition implementation used by the various terminals."""

PY_VERSION = "@rules_python//python/config_settings:python_version"

def _python_version_transition_impl(settings, attr):
    if attr.python_version:
        # Clobber the current value
        return {PY_VERSION: str(attr.python_version)}

    else:
        return {PY_VERSION: settings.get(PY_VERSION)}

python_version_transition = transition(
    implementation = _python_version_transition_impl,
    inputs = [PY_VERSION],
    outputs = [PY_VERSION],
)
