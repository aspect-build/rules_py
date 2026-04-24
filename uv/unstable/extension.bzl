"""Removed in rules_py v2.0.0 — use `@aspect_rules_py//uv:extensions.bzl` instead.

The `uv` module extension graduated to the stable `//uv:extensions.bzl`
location.
"""

fail(
    "rules_py v2.0.0: @aspect_rules_py//uv/unstable:extension.bzl has " +
    "been removed. Update your MODULE.bazel to use " +
    "`use_extension(\"@aspect_rules_py//uv:extensions.bzl\", \"uv\")` " +
    "instead. The extension itself is unchanged.",
)
