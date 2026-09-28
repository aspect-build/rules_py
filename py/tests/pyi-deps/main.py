"""Type-only dependencies are absent at run time."""

import importlib.util
import sys

import typed

for name in ("heavy", "cowsay"):
    if importlib.util.find_spec(name) is not None:
        sys.exit(f"pyi_deps leaked {name!r} onto sys.path")

assert typed.weigh.__annotations__["item"] == "Heavy"
print("ok")
