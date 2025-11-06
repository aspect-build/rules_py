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

# Vendored from rules_python's config_settings.bzl
# TODO: At least make this
_PYTHON_VERSION_FLAG = Label("@rules_python//python/config_settings:python_version")
_PYTHON_VERSION_MAJOR_MINOR_FLAG = Label("@rules_python//python/config_settings:python_version_major_minor")

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
    flag_value = ctx.attr._major_minor[config_common.FeatureFlagInfo].value

    # CI is, somehow, getting an empty string for the current flag value.
    # How isn't clear.
    if not flag_value:
        return [config_common.FeatureFlagInfo(value = "no")]

    current = tuple([
        int(x)
        for x in flag_value.split(".")
    ])
    at_least = tuple([int(x) for x in ctx.attr.at_least.split(".")])

    value = "yes" if current >= at_least else "no"
    return [config_common.FeatureFlagInfo(value = value)]

_python_version_at_least = rule(
    implementation = _python_version_at_least_impl,
    attrs = {
        "at_least": attr.string(mandatory = True),
        "_major_minor": attr.label(default = _PYTHON_VERSION_MAJOR_MINOR_FLAG),
    },
)
