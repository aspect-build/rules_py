"""Public API for Python interpreter provisioning."""

load("//py/private/interpreter:extension.bzl", _python_interpreters = "python_interpreters")

python_interpreters = _python_interpreters
