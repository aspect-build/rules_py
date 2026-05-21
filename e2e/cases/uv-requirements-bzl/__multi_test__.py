"""Imports every direct + transitive package the hub exposes.

Run from a py_test with deps = all_requirements; if any all_requirements
label fails to resolve or its py_library is wired wrong, one of these
imports fails."""

import cowsay
import dateutil
import six

assert hasattr(cowsay, "cow")
assert hasattr(dateutil, "__version__")
assert hasattr(six, "PY3")
print("multi-package hub: cowsay + dateutil + six importable via all_requirements")
