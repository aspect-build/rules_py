"""A rules_python library's src borrowed from another package is compiled at that
package's path. Files are checked before the import so the interpreter cannot
have written the cache itself."""

import os
import sys

helper_dir = os.path.join(os.environ["TEST_SRCDIR"], os.environ["TEST_WORKSPACE"], "cross-package")
names = set(os.listdir(helper_dir))
caches = os.listdir(os.path.join(helper_dir, "__pycache__")) if "__pycache__" in names else []

# rules_python deps keep their source, so CPython reads the __pycache__ layout.
assert "helper.py" in names, names
assert "helper.{}.pyc".format(sys.implementation.cache_tag) in caches, caches

sys.path.insert(0, helper_dir)
import helper

assert helper.answer() == 42
print("cross-package ok")
