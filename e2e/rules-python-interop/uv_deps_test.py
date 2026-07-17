"""Asserts a uv-hub wheel imports inside a venv assembled over the
rules_python-provisioned runtime — exercising whl_install's exec-tools
resolution in a module with no rules_py interpreters.
"""

import cowsay

assert cowsay.get_output_string("cow", "moo")
print("OK")
