import importlib
from pathlib import Path
import sys

from collision_namespace import shared


expected, fallback = sys.argv[1:3]
assert shared.VALUE == expected, (shared.VALUE, expected)
for unique in ("first", "second"):
    module = importlib.import_module(f"collision_namespace.{unique}")
    assert module.VALUE == unique, (module.VALUE, unique)

fallback_values = []
for entry in sys.path:
    root = Path(entry)
    # The fallback (collision-loser) wheel stays importable via its OWN
    # install-tree site-packages appended to sys.path, distinct from the
    # venv's merged site-packages (which carries the winner). That entry is
    # the wheel's natural runfiles path, whose install-tree directory ends
    # in `.install`.
    if not any(part.endswith(".install") for part in root.parts):
        continue
    for unique in ("first", "second"):
        if (root / "collision_namespace" / f"{unique}.py").is_file():
            fallback_values.append(unique)
assert fallback_values == [fallback], fallback_values
