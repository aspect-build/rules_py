"""Asserts a rules_py test can import a dep from a rules_python pip hub."""

import six

# The module must come from the pip hub's extracted wheel, not any other
# site-packages on the path.
assert "+pip+pip_312_six" in six.__file__, six.__file__
assert six.PY3

print("six from", six.__file__)
