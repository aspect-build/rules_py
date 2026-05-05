"""Module extensions for the uv integration.

Stable-path home for the `uv` extension that previously lived at
`@aspect_rules_py//uv/unstable:extension.bzl`.
"""

load("//uv/private/extension:defs.bzl", _uv = "uv")
load("//uv/private/extension:uv_bin.bzl", _uv_bin = "uv_bin")

uv = _uv
uv_bin = _uv_bin
