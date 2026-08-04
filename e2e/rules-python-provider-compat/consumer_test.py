"""Asserts the rules_py library's sources and import path reached this target.

Run by both an @rules_python py_test and a rules_py py_test, so the one
library must satisfy both rulesets' providers at once.
"""

import lib

assert lib.GREETING == "hello from rules_py", lib.GREETING
