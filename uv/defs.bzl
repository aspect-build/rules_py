"""Public rules and macros for the uv integration.

Stable-path home for the symbols that previously lived at
`@aspect_rules_py//uv/unstable:defs.bzl`. The `/unstable/` path fails
with a migration message in v2.0.0.
"""

load(
    "//uv/private/gazelle_manifest:defs.bzl",
    _gazelle_python_manifest = "gazelle_python_manifest",
)
load(
    "//uv/private/py_entrypoint_binary:defs.bzl",
    _py_console_script_binary = "py_console_script_binary",
    _py_entrypoint_binary = "py_entrypoint_binary",
)

gazelle_python_manifest = _gazelle_python_manifest
py_entrypoint_binary = _py_entrypoint_binary
py_console_script_binary = _py_console_script_binary
