"""Common transition implementation used by the various terminals."""

DEP_GROUP_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group"
_DEP_GROUP_BASELINE_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:baseline"

# Our own python_version flag, replacing the rules_python one.
PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_PYTHON_VERSION_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_python_version"

# rules_python's flag, kept for backward compatibility during migration.
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_RPY_VERSION_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_rules_python_version"

_BASELINE_UNSET = "<unset>"

# Every terminal-attr-driven flag with its baseline shadow. The attr value
# overrides the flag for the target's subtree; the baseline records the
# inherited value so `reset_python_flags_transition` can restore it on
# runtime-data edges. Adding a flag here sizes both transitions' inputs
# and outputs; `_python_transition_impl` supplies the override logic.
_FLAG_BASELINE_PAIRS = [
    (PYTHON_VERSION_FLAG, _PYTHON_VERSION_BASELINE_FLAG),
    (_RPY_VERSION_FLAG, _RPY_VERSION_BASELINE_FLAG),
    (DEP_GROUP_FLAG, _DEP_GROUP_BASELINE_FLAG),
]

_ALL_FLAGS = [flag for pair in _FLAG_BASELINE_PAIRS for flag in pair]

def _baseline(settings, flag, current):
    baseline = settings[flag]
    if baseline == _BASELINE_UNSET:
        return current
    return baseline

def _python_version(settings):
    return settings[PYTHON_VERSION_FLAG] or settings[_RPY_VERSION_FLAG]

def _python_transition_impl(settings, attr):
    acc = {}
    acc[_PYTHON_VERSION_BASELINE_FLAG] = _baseline(
        settings,
        _PYTHON_VERSION_BASELINE_FLAG,
        settings[PYTHON_VERSION_FLAG],
    )
    acc[_RPY_VERSION_BASELINE_FLAG] = _baseline(
        settings,
        _RPY_VERSION_BASELINE_FLAG,
        settings[_RPY_VERSION_FLAG],
    )
    if attr.python_version:
        version = str(attr.python_version)
    else:
        version = _python_version(settings)

    acc[PYTHON_VERSION_FLAG] = version
    acc[_RPY_VERSION_FLAG] = version

    # Set the dep_group transition. The attr is only present on `py_venv`
    # (rules without it propagate the inherited setting; `py_venv_exec`
    # is config-agnostic — its runfiles inherit the venv's wheels at
    # whatever DEP_GROUP_FLAG the venv resolved under).
    dep_group = getattr(attr, "dep_group", None)
    if dep_group:
        acc[DEP_GROUP_FLAG] = str(dep_group)
        acc[_DEP_GROUP_BASELINE_FLAG] = _baseline(
            settings,
            _DEP_GROUP_BASELINE_FLAG,
            settings[DEP_GROUP_FLAG],
        )
    else:
        acc[DEP_GROUP_FLAG] = settings[DEP_GROUP_FLAG]
        acc[_DEP_GROUP_BASELINE_FLAG] = settings[_DEP_GROUP_BASELINE_FLAG]

    return acc

python_transition = transition(
    implementation = _python_transition_impl,
    inputs = _ALL_FLAGS,
    outputs = _ALL_FLAGS,
)

# Runtime data is outside the Python environment selected by terminal attrs.
# Return every setting those attrs can override to its inherited value, then
# clear the scratch state so data targets share the caller's canonical
# configuration.
def _reset_python_flags_transition_impl(settings, _attr):
    acc = {}
    for flag, baseline_flag in _FLAG_BASELINE_PAIRS:
        acc[flag] = _baseline(settings, baseline_flag, settings[flag])
        acc[baseline_flag] = _BASELINE_UNSET
    return acc

reset_python_flags_transition = transition(
    implementation = _reset_python_flags_transition_impl,
    inputs = _ALL_FLAGS,
    outputs = _ALL_FLAGS,
)
