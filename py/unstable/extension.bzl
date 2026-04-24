"""Removed in rules_py v2.0.0 — use `@aspect_rules_py//py:extensions.bzl` instead.

The `python_interpreters` module extension graduated to the stable
`//py:extensions.bzl` location.
"""

fail(
    "rules_py v2.0.0: @aspect_rules_py//py/unstable:extension.bzl has " +
    "been removed. Update your MODULE.bazel to use " +
    "`use_extension(\"@aspect_rules_py//py:extensions.bzl\", \"python_interpreters\")` " +
    "instead. The extension itself is unchanged.",
)
