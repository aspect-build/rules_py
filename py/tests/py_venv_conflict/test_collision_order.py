import importlib
import subprocess
import sys

from collision_namespace import shared


expected = sys.argv[1]
assert shared.VALUE == expected, (shared.VALUE, expected)
for unique in ("first", "second"):
    module = importlib.import_module(f"collision_namespace.{unique}")
    assert module.VALUE == unique, (module.VALUE, unique)
result = subprocess.run(
    [sys.prefix + "/bin/collision-order"],
    check=True,
    capture_output=True,
    text=True,
)
assert result.stdout == expected + "\n", result.stdout
