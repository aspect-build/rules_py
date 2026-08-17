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
