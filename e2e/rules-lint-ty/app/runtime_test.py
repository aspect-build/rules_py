"""A pyi_dep is not importable at run time."""

import importlib.util

from app.app import norm

assert importlib.util.find_spec("shapes") is None, "pyi_deps leaked onto sys.path"
assert norm.__annotations__["point"] == "Point"
