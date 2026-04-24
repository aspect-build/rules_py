"""Removed in rules_py v2.0.0 — load from `@aspect_rules_py//uv:defs.bzl` instead.

The `gazelle_python_manifest`, `py_entrypoint_binary`, and
`py_console_script_binary` macros graduated to the stable
`//uv:defs.bzl` load path.
"""

fail(
    "rules_py v2.0.0: @aspect_rules_py//uv/unstable:defs.bzl has been " +
    "removed. Update your load() statements to use " +
    "`@aspect_rules_py//uv:defs.bzl` instead. All three symbols " +
    "(gazelle_python_manifest, py_entrypoint_binary, " +
    "py_console_script_binary) are re-exported from the stable path " +
    "unchanged.",
)
