"""Asserts a uv-hub wheel imports inside a venv assembled over the
rules_python-provisioned runtime — exercising whl_install's exec-tools
resolution at a version no rules_py interpreter hub covers.
"""

import cowsay

assert cowsay.get_output_string("cow", "moo")
print("OK")
