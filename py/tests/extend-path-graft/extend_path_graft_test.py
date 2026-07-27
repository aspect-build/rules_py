"""A pkgutil.extend_path package must still see its collision loser.

`graftpkg` is a plain regular package on both sides -- neither wheel declares
a namespace -- so the collision resolves by projecting the winner into the
venv site-packages and leaving the loser on its whole-wheel `.pth` fallback.

The winner's `__init__.py` calls `pkgutil.extend_path`, which rescans sys.path
for directories named `graftpkg` and appends them to `__path__`. Drop the
loser's fallback and there is nothing left to find: `from_loser` raises
ImportError.
"""

import graftpkg
from graftpkg import from_loser, from_winner

assert from_winner.VALUE == "winner", from_winner.VALUE
assert from_loser.VALUE == "loser", from_loser.VALUE

# The graft is what makes the loser reachable: __path__ must have picked up a
# second directory beyond the one projected into the venv site-packages.
assert len(graftpkg.__path__) >= 2, graftpkg.__path__
