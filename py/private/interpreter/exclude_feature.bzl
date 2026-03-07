"""A repeatable string flag for excluding interpreter features.

Usage:
    bazel build //... \
        --@aspect_rules_py//py/private/interpreter:exclude_feature=headers \
        --@aspect_rules_py//py/private/interpreter:exclude_feature=tkinter

Each value accumulates. In a generated interpreter repo, a config_setting
like:

    config_setting(
        name = "_exclude_headers",
        flag_values = {"@aspect_rules_py//py/private/interpreter:exclude_feature": "headers"},
    )

will match if "headers" is among the accumulated --exclude_feature values.
"""

_VALID_FEATURES = [
    "headers",
    "docs",
    "tkinter",
    "idle",
    "ensurepip",
    "config",
    "pydoc",
    "lib2to3",
    "turtle",
]

def _exclude_feature_flag_impl(ctx):
    values = ctx.build_setting_value
    for v in values:
        if v and v not in _VALID_FEATURES:
            fail("Invalid exclude_feature '{}'. Valid values: {}".format(v, ", ".join(_VALID_FEATURES)))
    return []

exclude_feature_flag = rule(
    implementation = _exclude_feature_flag_impl,
    build_setting = config.string(flag = True, allow_multiple = True),
    doc = "Repeatable flag to exclude optional interpreter components. Pass multiple times to exclude several features.",
)

# Feature definitions: maps feature name to the glob patterns it claims
# from the interpreter install tree. Used by the interpreter repo rule
# to generate per-feature filegroups.
INTERPRETER_FEATURES = {
    "headers": {
        "include": ["include/**"],
        "doc": "C headers for building native extensions",
    },
    "docs": {
        "include": ["share/**"],
        "doc": "Man pages and documentation",
    },
    "tkinter": {
        "include": [
            "lib/python{major}.{minor}/tkinter/**",
            "lib/python{major}.{minor}/lib-dynload/_tkinter*",
        ],
        "doc": "Tk GUI bindings",
    },
    "idle": {
        "include": ["lib/python{major}.{minor}/idlelib/**"],
        "doc": "IDLE editor",
    },
    "ensurepip": {
        "include": ["lib/python{major}.{minor}/ensurepip/**"],
        "doc": "pip bootstrapper (bundled pip/setuptools wheels)",
    },
    "config": {
        "include": ["lib/python{major}.{minor}/config-*/**"],
        "doc": "Build/link configuration and static libraries",
    },
    "pydoc": {
        "include": ["lib/python{major}.{minor}/pydoc_data/**"],
        "doc": "pydoc HTML templates",
    },
    "lib2to3": {
        "include": ["lib/python{major}.{minor}/lib2to3/**"],
        "doc": "Python 2 to 3 conversion tool",
    },
    "turtle": {
        "include": [
            "lib/python{major}.{minor}/turtle.py",
            "lib/python{major}.{minor}/turtledemo/**",
        ],
        "doc": "Turtle graphics",
    },
}
