"""Generate interpreter ABI config_settings for wheel selection.

Each ABI tag extracted from a wheel filename (e.g. ``cp312``, ``cp312t``,
``cp312dmu``) is mapped to a ``config_setting_group`` that combines a Python
version check with interpreter feature flags. The feature flags are backed by
``bool_flag`` targets defined in ``//py/private/interpreter`` and are set by
the interpreter toolchain provisioning system.

Known problems:
    - Combinatorial explosion: the nested loops over ``d``, ``m``, ``t``, ``u``
      generate thousands of ``config_setting_group`` targets, many of which
      represent ABI combinations that do not exist in practice (e.g.
      ``py2`` + ``freethreaded``). This bloats the Bazel analysis phase.
    - Obsolete features: ``d`` (pydebug), ``m`` (pymalloc) and ``u``
      (wide_unicode) are largely irrelevant for modern Python 3 wheels, yet
      they are still materialised for every interpreter/minor version pair.
    - The original author left an unresolved ``FIXME`` about whether there is
      a better way to model the ABI matrix.
    - This module assumes that the only relevant interpreters are CPython
      (``cp``) and the generic ``py``. PyPy, Jython and IronPython are
      commented out and not supported.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")

_PYDEBUG_FLAG = "//py/private/interpreter:pydebug"
_PYMALLOC_FLAG = "//py/private/interpreter:pymalloc"
_FREETHREADING_FLAG = "//py/private/interpreter:freethreaded"
_WIDE_UNICODE_FLAG = "//py/private/interpreter:wide_unicode"

def generate(visibility):
    """Materialise ABI config_setting targets for wheel resolution.

    Creates four groups of targets:

    1. A fallback ``:none`` group that matches ``//conditions:default``.
    2. Enabled/disabled ``config_setting`` pairs for each interpreter feature
       flag (pydebug, pymalloc, freethreaded, wide_unicode).
    3. Version base groups (``is_cp312``, ``is_py38``, etc.) that only check
       the Python version constraint.
    4. Full ABI tag groups that cross the version base with every combination
       of the four feature flags, producing names such as ``cp312dmt``.

    Additionally an ``:abi3`` alias is created pointing to ``:is_py33``
    because wheels tagged with ``abi3`` are guaranteed compatible with
    CPython 3.3 and later.

    Args:
        visibility: Visibility list passed to every generated target.
    """
    selects.config_setting_group(
        name = "none",
        match_all = [
            "//conditions:default",
        ],
    )

    native.config_setting(
        name = "pydebug_enabled",
        flag_values = {_PYDEBUG_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "pydebug_disabled",
        flag_values = {_PYDEBUG_FLAG: "false"},
        visibility = visibility,
    )

    native.config_setting(
        name = "pymalloc_enabled",
        flag_values = {_PYMALLOC_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "pymalloc_disabled",
        flag_values = {_PYMALLOC_FLAG: "false"},
        visibility = visibility,
    )

    native.config_setting(
        name = "freethreading_enabled",
        flag_values = {_FREETHREADING_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "freethreading_disabled",
        flag_values = {_FREETHREADING_FLAG: "false"},
        visibility = visibility,
    )

    native.config_setting(
        name = "wide_unicode_enabled",
        flag_values = {_WIDE_UNICODE_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "wide_unicode_disabled",
        flag_values = {_WIDE_UNICODE_FLAG: "false"},
        visibility = visibility,
    )

    native.alias(
        name = "abi3",
        actual = "is_py33",
        visibility = visibility,
    )

    for interpreter in INTERPRETERS:
        for major in MAJORS:
            for minor in MINORS:
                selects.config_setting_group(
                    name = "is_{}{}{}".format(interpreter, major, minor),
                    match_all = [
                        "//uv/private/constraints/python:py{}{}".format(major, minor),
                    ],
                    visibility = visibility,
                )

                for d in [False, True]:
                    for m in [False, True]:
                        for t in [False, True]:
                            for u in [False, True]:
                                selects.config_setting_group(
                                    name = "{0}{1}{2}{3}{4}{5}{6}".format(
                                        interpreter,
                                        major,
                                        minor,
                                        "d" if d else "",
                                        "m" if m else "",
                                        "t" if t else "",
                                        "u" if u else "",
                                    ),
                                    match_all = (
                                        [
                                            ":is_{}{}{}".format(interpreter, major, minor),
                                        ] +
                                        ([":pydebug_enabled"] if d else [":pydebug_disabled"]) +
                                        ([":pymalloc_enabled"] if m else [":pymalloc_disabled"]) +
                                        ([":freethreading_enabled"] if t else [":freethreading_disabled"]) +
                                        ([":wide_unicode_enabled"] if u else [":wide_unicode_disabled"])
                                    ),
                                    visibility = visibility,
                                )
