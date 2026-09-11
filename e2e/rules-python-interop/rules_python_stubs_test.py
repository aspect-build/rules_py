"""A rules_python library's `pyi_srcs` reach a rules_py consumer's runfiles.

The stub is metadata in rules_python's PyInfo, never in its own runfiles; the
rules_py venv must carry it beside the module it annotates so a type checker
pointed at the venv resolves it.
"""

import os

import stubbed

stub = os.path.splitext(stubbed.__file__)[0] + ".pyi"
assert os.path.exists(stub), "missing type stub next to " + stubbed.__file__
assert stubbed.describe(1) == "stubbed 1"
