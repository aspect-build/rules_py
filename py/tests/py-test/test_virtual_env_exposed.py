import os

# `expose_venv = True` variant of the VIRTUAL_ENV assertion in
# test_env_vars.py: here the sibling venv is the public, runnable
# `:test_virtual_env_exposed.venv` target. The merged runtime env must
# still point VIRTUAL_ENV at the venv root (rootpath form).
_expected = "py/tests/py-test/.test_virtual_env_exposed.venv"
_actual = os.environ.get("VIRTUAL_ENV")
assert _actual == _expected, f"Expected VIRTUAL_ENV '{_expected}', but got '{_actual}'"
