"""Stable public API for uv module extensions.

Graduated from `@aspect_rules_py//uv/unstable:extension.bzl` in rules_py v2.0.0.
"""

load("//uv/private/extension:defs.bzl", _uv = "uv")
load("//uv/private/extension:uv_bin.bzl", _uv_bin = "uv_bin")

uv = _uv
uv_bin = _uv_bin
