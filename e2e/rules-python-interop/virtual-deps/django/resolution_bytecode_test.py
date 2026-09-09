"""A virtual dep resolved to a rules_python pip hub package gets bytecode from
rules_py's aspect over `resolutions`; pyc_only would otherwise fail analysis
listing the hub's sources. The hub's own runfiles still carry the source."""

import os

import django

assert "+pip+django_312_django" in django.__file__, django.__file__
assert django.__file__.endswith("__init__.py"), django.__file__
legacy = django.__file__[: -len(".py")] + ".pyc"
assert os.path.exists(legacy), os.listdir(os.path.dirname(django.__file__))
print("OK")
