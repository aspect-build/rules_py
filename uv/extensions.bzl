"""Module extensions for the uv integration.

Stable-path home for the `uv` extension that previously lived at
`@aspect_rules_py//uv/unstable:extension.bzl`. The `/unstable/` path
fails with a migration message in v2.0.0.
"""

load("//uv/private/extension:defs.bzl", _uv = "uv")

uv = _uv
