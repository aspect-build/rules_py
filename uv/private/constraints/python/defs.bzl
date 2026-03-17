load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def supported_python(python_tag):
    """Predicate.

    Indicate whether the current `pip` implementation supports the python
    represented by a given wheel abi tag. Allows for filtering out of wheels for
    currently unsupported pythons, being:

    - PyPy which has its own abi versioning scheme
    - Jython
    - IronPython

    Explicitly allows only the `py` (generic) and `cp` (CPython) interpreters.

    Args:
        python_tag (str): A wheel abi tag

    Returns:
        bool; whether the python is supported and can be configured or not.

    """

    # See https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/#python-tag

    if python_tag.startswith("pypy"):
        return False
    elif python_tag.startswith("cp") or python_tag.startswith("py"):
        return True
    else:
        return False

_PYTHON_VERSION_MAJOR_MINOR_FLAG = Label("@rules_python//python/config_settings:python_version_major_minor")
_ARPY_PYTHON_VERSION_FLAG = Label("@aspect_rules_py//py/private/interpreter:python_version")

def is_python_version_at_least(name, version = None, visibility = visibility, **kwargs):
    version = version or name
    flag_name = "_{}_flag".format(name)
    native.config_setting(
        name = name,
        flag_values = {
            flag_name: "yes",
        },
        visibility = visibility,
    )
    _python_version_at_least(
        name = flag_name,
        at_least = version,
        visibility = ["//visibility:private"],
        **kwargs
    )

def _python_version_at_least_impl(ctx):
    # Read from both sources
    rpy_value = ctx.attr._major_minor[config_common.FeatureFlagInfo].value
    arpy_raw = ctx.attr._arpy_version[BuildSettingInfo].value

    # Normalize aspect_rules_py flag to major.minor
    arpy_value = ""
    if arpy_raw:
        parts = arpy_raw.split(".")
        if len(parts) >= 2:
            arpy_value = "{}.{}".format(parts[0], parts[1])

    # Error on disagreement when both are set
    if arpy_value and rpy_value and arpy_value != rpy_value:
        fail(
            "Python version mismatch: " +
            "@aspect_rules_py//py/private/interpreter:python_version is {}, ".format(arpy_value) +
            "but @rules_python python_version_major_minor is {}. ".format(rpy_value) +
            "These must agree.",
        )

    # Aspect flag is authoritative; rules_python is fallback
    flag_value = arpy_value or rpy_value

    if not flag_value:
        return [config_common.FeatureFlagInfo(value = "no")]

    current = tuple([int(x) for x in flag_value.split(".")])
    at_least = tuple([int(x) for x in ctx.attr.at_least.split(".")])

    value = "yes" if current >= at_least else "no"
    return [config_common.FeatureFlagInfo(value = value)]

_python_version_at_least = rule(
    implementation = _python_version_at_least_impl,
    attrs = {
        "at_least": attr.string(mandatory = True),
        "_major_minor": attr.label(default = _PYTHON_VERSION_MAJOR_MINOR_FLAG),
        "_arpy_version": attr.label(default = _ARPY_PYTHON_VERSION_FLAG),
    },
)
