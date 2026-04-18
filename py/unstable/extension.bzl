"""Unstable/experimental extension for Python interpreter provisioning.

This module re-exports the python_interpreters extension from the private
implementation. It's considered unstable and may change without notice.
"""

load(
    "//py/private/interpreter:extension.bzl",
    _interpreter_extension = "python_interpreters",
)

# Re-export the extension
python_interpreters = _interpreter_extension
