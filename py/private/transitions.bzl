"""Common transition implementation used by the various terminals."""

def _python_version_transition_impl(_, attr):
    if not attr.python_version:
        return {}
    return {"@rules_python//python/config_settings:python_version": str(attr.python_version)}

python_version_transition = transition(
    implementation = _python_version_transition_impl,
    inputs = [],
    outputs = ["@rules_python//python/config_settings:python_version"],
)
