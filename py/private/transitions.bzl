"""Common transition implementation used by the various terminals."""

DEP_GROUP_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group"
_DEP_GROUP_BASELINE_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:baseline"

# Only terminal rules read this flag (as the default for an unset `pyc`
# attribute); it never configures the graph below them, so it is not part of
# python_transition.
PYC_FLAG = "@aspect_rules_py//py:pyc"

# Our own python_version flag, replacing the rules_python one.
PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_PYTHON_VERSION_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_python_version"

# rules_python's flag, kept for backward compatibility during migration.
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_RPY_VERSION_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_rules_python_version"

_FREETHREADED_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_FREETHREADED_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_freethreaded"
_RPY_FREETHREADED_FLAG = "@rules_python//python/config_settings:py_freethreaded"
_RPY_FREETHREADED_BASELINE_FLAG = "@aspect_rules_py//py/private/interpreter:baseline_rules_python_freethreaded"

_BASELINE_UNSET = "<unset>"

# Every terminal-attr-driven flag with its baseline shadow. The attr value
# overrides the flag for the target's subtree; the baseline records the
# inherited value so `reset_python_flags_transition` can restore it on
# runtime-data edges (bool flags are stringified as yes/no in the baseline).
# Adding a flag here sizes both transitions' inputs and outputs;
# `_python_transition_impl` supplies the override logic.
_FLAG_BASELINE_PAIRS = [
    (PYTHON_VERSION_FLAG, _PYTHON_VERSION_BASELINE_FLAG),
    (_RPY_VERSION_FLAG, _RPY_VERSION_BASELINE_FLAG),
    (_FREETHREADED_FLAG, _FREETHREADED_BASELINE_FLAG),
    (_RPY_FREETHREADED_FLAG, _RPY_FREETHREADED_BASELINE_FLAG),
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

def _freethreaded_mode(settings):
    return "true" if settings[_FREETHREADED_FLAG] else "false"

# The bool flag has no unset state, so inheriting also honors rules_python's
# flag, mirroring _python_version.
def _inherited_freethreaded_mode(settings):
    if settings[_FREETHREADED_FLAG] or settings[_RPY_FREETHREADED_FLAG] == "yes":
        return "true"
    return "false"

# Free-threaded CPython builds exist from 3.13 onward; toolchain resolution
# remains the authority for which exact versions ship one.
def _freethreaded_available(version):
    parts = version.split(".")
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return True
    return (int(parts[0]), int(parts[1])) >= (3, 13)

def _python_transition_impl(settings, attr):
    return _python_transition_base(settings, attr, validate = True)

def _python_transition_base(settings, attr, validate):
    acc = {}
    acc[_FREETHREADED_BASELINE_FLAG] = _baseline(
        settings,
        _FREETHREADED_BASELINE_FLAG,
        _freethreaded_mode(settings),
    )
    acc[_RPY_FREETHREADED_BASELINE_FLAG] = _baseline(
        settings,
        _RPY_FREETHREADED_BASELINE_FLAG,
        settings[_RPY_FREETHREADED_FLAG],
    )
    mode = getattr(attr, "freethreaded", "") or _inherited_freethreaded_mode(settings)
    acc[_FREETHREADED_FLAG] = mode == "true"

    # Keep rules_python native extensions on the interpreter's ABI,
    # translated into that flag's own yes/no vocabulary.
    acc[_RPY_FREETHREADED_FLAG] = "yes" if mode == "true" else "no"
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

    if validate and mode == "true" and version and not _freethreaded_available(version):
        fail("{}: free-threaded mode requires Python 3.13+, but the selected python_version is \"{}\"; set freethreaded = False or raise python_version".format(
            attr.name,
            version,
        ))

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

# The launcher -> venv edge. With no launcher `python_version` or
# `freethreaded` the inherited settings pass through untouched. Validation
# never runs here: the edge produces an intermediate configuration, and the
# venv's own rule transition — which always applies next and may override
# either half of a version/GIL combination — is the sole authority for
# rejecting an incompatible final configuration.
def _venv_python_transition_impl(settings, attr):
    if not attr.python_version and not attr.freethreaded:
        return {flag: settings[flag] for flag in _ALL_FLAGS}
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
        is_bool = type(settings[flag]) == "bool"
        current = ("true" if settings[flag] else "false") if is_bool else settings[flag]
        restored = _baseline(settings, baseline_flag, current)
        acc[flag] = restored == "true" if is_bool else restored
        acc[baseline_flag] = _BASELINE_UNSET
    return acc

reset_python_flags_transition = transition(
    implementation = _reset_python_flags_transition_impl,
    inputs = _ALL_FLAGS,
    outputs = _ALL_FLAGS,
)

def _reset_pyc_transition_impl(settings, _attr):
    return {PYC_FLAG: "source"}

reset_pyc_transition = transition(
    implementation = _reset_pyc_transition_impl,
    inputs = [PYC_FLAG],
    outputs = [PYC_FLAG],
)
