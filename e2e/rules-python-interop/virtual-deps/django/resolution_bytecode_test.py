"""A virtual dep resolved to a rules_python pip hub package is reached through
`resolutions`, so pyc_only analyzes; hub packages are never compiled and run
from the source their own runfiles carry."""

import os

import django

assert "+pip+django_312_django" in django.__file__, django.__file__
assert django.__file__.endswith("__init__.py"), django.__file__
sourceless = django.__file__[: -len(".py")] + ".pyc"
assert not os.path.exists(sourceless), os.listdir(os.path.dirname(django.__file__))
print("OK")
