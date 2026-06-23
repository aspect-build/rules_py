import importlib
import subprocess
import sys

import collision_order
from collision_namespace import shared


expected = sys.argv[1]
assert collision_order.VALUE == expected, (collision_order.VALUE, expected)
assert shared.VALUE == expected, (shared.VALUE, expected)
for unique in ("direct", "transitive"):
    module = importlib.import_module(f"collision_namespace.{unique}")
    assert module.VALUE == unique, (module.VALUE, unique)
result = subprocess.run(
    [sys.prefix + "/bin/collision-order"],
    check=True,
    capture_output=True,
    text=True,
)
assert result.stdout == expected + "\n", result.stdout
