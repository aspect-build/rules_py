"""A repeatable string flag for selecting interpreter build features.

Usage:
    bazel build //... \
        --@aspect_rules_py//py/private/interpreter:interpreter_feature=freethreaded

Each value accumulates. Derived `interpreter_has_feature` rules read the
accumulated list and expose FeatureFlagInfo, enabling both presence and
absence matching via config_setting flag_values.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

# Valid interpreter feature values. These correspond to the single-letter
# suffixes in wheel ABI tags:
#   d (pydebug), m (pymalloc), t (freethreaded), u (wide_unicode)
INTERPRETER_FEATURES = [
    "freethreaded",
    "pydebug",
    "pymalloc",
    "wide_unicode",
]

def _interpreter_feature_flag_impl(ctx):
    values = ctx.build_setting_value
    for v in values:
        if v and v not in INTERPRETER_FEATURES:
            fail("Invalid interpreter_feature '{}'. Valid values: {}".format(v, ", ".join(INTERPRETER_FEATURES)))
    return []

interpreter_feature_flag = rule(
    implementation = _interpreter_feature_flag_impl,
    build_setting = config.string(flag = True, allow_multiple = True),
    doc = "Repeatable flag to select interpreter build features.",
)

def _interpreter_has_feature_impl(ctx):
    """Returns "true" if the named feature is in the --interpreter_feature list."""
    features = ctx.attr._feature_flag[BuildSettingInfo].value
    present = ctx.attr.feature in features
    return [config_common.FeatureFlagInfo(value = "true" if present else "false")]

interpreter_has_feature = rule(
    implementation = _interpreter_has_feature_impl,
    attrs = {
        "feature": attr.string(mandatory = True),
        "_feature_flag": attr.label(
            default = "//py/private/interpreter:interpreter_feature",
        ),
    },
    doc = "Derived flag: exposes whether a feature is present in --interpreter_feature.",
)
