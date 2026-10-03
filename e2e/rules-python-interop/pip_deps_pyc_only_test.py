"""A pip hub package is never compiled by rules_py: under sourceless it still
ships and imports from its source, with no sourceless bytecode beside it."""

import os

import six

assert "+pip+pip_311_six" in six.__file__, six.__file__
assert six.__file__.endswith("six.py"), six.__file__
assert not os.path.exists(six.__file__[: -len(".py")] + ".pyc"), six.__file__
