"""A repeatable string flag for excluding interpreter features.

Usage:
    bazel build //... \
        --@rules_py//py/private/interpreter:exclude_feature=headers \
        --@rules_py//py/private/interpreter:exclude_feature=tkinter

Each value accumulates. In a generated interpreter repo, a config_setting
like:

    config_setting(
        name = "_exclude_headers",
        flag_values = {"@rules_py//py/private/interpreter:exclude_feature": "headers"},
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
# directory: lib/python3.14 or lib/python3.14t on POSIX, Lib on Windows.
# `include` patterns apply to every install layout and may match nothing
# where a layout lacks the feature. A feature whose files sit at different
# paths in the POSIX and Windows layouts lists them in `include_posix` and
# `include_windows`.
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
        "include": ["{stdlib}/tkinter/**"],
        "include_posix": [
            "{stdlib}/lib-dynload/_tkinter*",
            "lib/libtcl*",
            "lib/libtk*",
            "lib/tcl*/**",
            "lib/tk*/**",
            "lib/itcl*/**",
            "lib/thread*/**",
        ],
        "include_windows": [
            "DLLs/_tkinter*.pyd",
            "DLLs/tcl*.dll",
            "DLLs/tk*.dll",
            # Tcl's zlib. CPython compiles its own zlib into the interpreter DLL:
            # https://github.com/python/cpython/blob/v3.13.5/PCbuild/pythoncore.vcxproj
            "DLLs/zlib1.dll",
            "tcl/**/*.dll",
            "tcl/**/*.py",
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
