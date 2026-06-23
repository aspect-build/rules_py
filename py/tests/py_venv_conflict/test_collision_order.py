import importlib
import subprocess
import sys

import collision_order
from atomic import shared as atomic_shared
from collision_namespace import shared


expected = sys.argv[1]
assert collision_order.VALUE == expected, (collision_order.VALUE, expected)
assert atomic_shared.VALUE == expected, (atomic_shared.VALUE, expected)
assert shared.VALUE == expected, (shared.VALUE, expected)
for unique in ("direct", "transitive"):
    module = importlib.import_module(f"collision_namespace.{unique}")
    assert module.VALUE == unique, (module.VALUE, unique)
    sibling = importlib.import_module(f"{unique}_sibling.value")
    assert sibling.VALUE == unique, (sibling.VALUE, unique)
    atomic_unique = f"atomic.only_{unique}"
    if unique == expected:
        module = importlib.import_module(atomic_unique)
        assert module.VALUE == unique, (module.VALUE, unique)
    else:
        try:
            importlib.import_module(atomic_unique)
        except ModuleNotFoundError:
            pass
        else:
            raise AssertionError(f"atomic collision loser leaked through .pth: {atomic_unique}")
result = subprocess.run(
    [sys.prefix + "/bin/collision-order"],
    check=True,
    capture_output=True,
    text=True,
)
assert result.stdout == expected + "\n", result.stdout
