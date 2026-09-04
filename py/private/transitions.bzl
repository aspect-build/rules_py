"""Common transition implementation used by the various terminals."""

_DEP_GROUP_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group"
_DEP_GROUP_BASELINE_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:baseline"

# Our own python_version flag, replacing the rules_python one.
_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_PYTHON_VERSION_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_python_version"

# rules_python's flag, kept for backward compatibility during migration.
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_RPY_VERSION_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_rules_python_version"

_FREETHREADED_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_FREETHREADED_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_freethreaded"
_RPY_FREETHREADED_FLAG = "@rules_python//python/config_settings:py_freethreaded"
_RPY_FREETHREADED_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_rules_python_freethreaded"

_BASELINE_UNSET = "<unset>"

# Every terminal-attr-driven flag with its baseline shadow. A baseline records
# the inherited value the first time a terminal changes the flag so
# `reset_python_flags_transition` can restore it on runtime-data edges (the
# bool flag is stored as "true"/"false"). A terminal that leaves every flag at
# its inherited value is a no-op: it captures no baseline, so its subtree
# shares the caller's configuration.
_FLAG_BASELINE_PAIRS = [
    (_PYTHON_VERSION_FLAG, _PYTHON_VERSION_BASELINE_FLAG),
    (_FREETHREADED_FLAG, _FREETHREADED_BASELINE_FLAG),
    (_DEP_GROUP_FLAG, _DEP_GROUP_BASELINE_FLAG),

    # rules_python's flags are kept in sync with ours, so they share the same baseline.
    (_RPY_VERSION_FLAG, _RPY_VERSION_BASELINE_FLAG),
    (_RPY_FREETHREADED_FLAG, _RPY_FREETHREADED_BASELINE_FLAG),
]

_ALL_FLAGS = [flag for pair in _FLAG_BASELINE_PAIRS for flag in pair]

def _stringify(value):
    if type(value) == "bool":
        return "true" if value else "false"
    return value

def _capture_baseline(settings, flag, baseline_flag, new_value):
    if settings[baseline_flag] == _BASELINE_UNSET and new_value != settings[flag]:
        return _stringify(settings[flag])
    return settings[baseline_flag]

# Free-threaded CPython builds exist from 3.13 onward; toolchain resolution
# remains the authority for which exact versions ship one.
def _freethreaded_available(version):
    parts = version.split(".")
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return True
    return (int(parts[0]), int(parts[1])) >= (3, 13)

def _python_transition_base(settings, attr, validate):
    if attr.freethreaded:
        freethreaded = attr.freethreaded == "true"
    else:
        # The bool flag has no unset state, so inheriting also honors
        # rules_python's flag.
        freethreaded = settings[_FREETHREADED_FLAG] or settings[_RPY_FREETHREADED_FLAG] == "yes"

    version = attr.python_version or settings[_PYTHON_VERSION_FLAG] or settings[_RPY_VERSION_FLAG]

    if validate and freethreaded and version and not _freethreaded_available(version):
        fail("{}: free-threaded mode requires Python 3.13+, but the selected python_version is \"{}\"; set freethreaded = False or raise python_version".format(
            attr.name,
            version,
        ))

    acc = {
        _FREETHREADED_FLAG: freethreaded,
        _PYTHON_VERSION_FLAG: version,
        # Only `py_venv` carries the attr; other rules inherit the group.
        _DEP_GROUP_FLAG: getattr(attr, "dep_group", "") or settings[_DEP_GROUP_FLAG],

        # Keep rules_python names alive
        _RPY_FREETHREADED_FLAG: "yes" if freethreaded else "no",
        _RPY_VERSION_FLAG: version,
    }
    for flag, baseline_flag in _FLAG_BASELINE_PAIRS:
        acc[baseline_flag] = _capture_baseline(settings, flag, baseline_flag, acc[flag])
    return acc

def _python_transition_impl(settings, attr):
    return _python_transition_base(settings, attr, validate = True)

python_transition = transition(
    implementation = _python_transition_impl,
    inputs = _ALL_FLAGS,
    outputs = _ALL_FLAGS,
)

# The launcher -> venv edge. Validation never runs here: the venv's own rule
# transition always applies next, may override either half of a version/GIL
# combination, and is the sole authority for rejecting the final configuration.
def _venv_python_transition_impl(settings, attr):
    return _python_transition_base(settings, attr, validate = False)

venv_python_transition = transition(
    implementation = _venv_python_transition_impl,
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
        baseline = settings[baseline_flag]
        if baseline == _BASELINE_UNSET:
            acc[flag] = settings[flag]
        elif type(settings[flag]) == "bool":
            acc[flag] = baseline == "true"
        else:
            acc[flag] = baseline
        acc[baseline_flag] = _BASELINE_UNSET
    return acc

reset_python_flags_transition = transition(
    implementation = _reset_python_flags_transition_impl,
    inputs = _ALL_FLAGS,
    outputs = _ALL_FLAGS,
)
