"""
Preview features.

Unstable extension for Python interpreter provisioning.
No promises are made about compatibility across releases.
"""

load("//py/private/interpreter:extension.bzl", _python_interpreters = "python_interpreters")

python_interpreters = _python_interpreters
