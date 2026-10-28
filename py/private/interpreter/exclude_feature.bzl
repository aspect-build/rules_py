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

def _exclude_feature_flag_impl(ctx):
    values = ctx.build_setting_value
    for v in values:
        if v and v not in INTERPRETER_FEATURES:
            fail("Invalid exclude_feature '{}'. Valid values: {}".format(v, ", ".join(INTERPRETER_FEATURES.keys())))
    return []

exclude_feature_flag = rule(
    implementation = _exclude_feature_flag_impl,
    build_setting = config.string(flag = True, allow_multiple = True),
    doc = "Repeatable flag to exclude optional interpreter components. Pass multiple times to exclude several features.",
)

# Feature definitions: maps feature name to the glob patterns it claims
# from the interpreter install tree. Used by the interpreter repo rule
# to generate per-feature filegroups. `{stdlib}` is the standard library
# directory, such as lib/python3.14t for a free-threaded build.
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
            "{stdlib}/tkinter/**",
            "{stdlib}/lib-dynload/_tkinter*",
            "lib/libtcl*",
            "lib/libtk*",
            "lib/tcl*/**",
            "lib/tk*/**",
            "lib/itcl*/**",
            "lib/thread*/**",
        ],
        "doc": "Tk GUI bindings",
    },
    "idle": {
        "include": ["{stdlib}/idlelib/**"],
        "doc": "IDLE editor",
    },
    "ensurepip": {
        "include": ["{stdlib}/ensurepip/**"],
        "doc": "pip bootstrapper (bundled pip/setuptools wheels)",
    },
    "config": {
        "include": ["{stdlib}/config-*/**"],
        "doc": "Build/link configuration and static libraries",
    },
    "pydoc": {
        "include": ["{stdlib}/pydoc_data/**"],
        "doc": "pydoc HTML templates",
    },
    "lib2to3": {
        "include": ["{stdlib}/lib2to3/**"],
        "doc": "Python 2 to 3 conversion tool",
    },
    "turtle": {
        "include": [
            "{stdlib}/turtle.py",
            "{stdlib}/turtledemo/**",
        ],
        "doc": "Turtle graphics",
    },
}
