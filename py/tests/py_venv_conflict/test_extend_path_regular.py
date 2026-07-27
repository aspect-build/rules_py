"""A pkgutil.extend_path winner still needs its collision losers on sys.path.

Neither wheel declares a namespace: both ship a REGULAR `collision_order`
package (it has `__init__.py`) with a native sibling root, so the collision
resolves through the native branch with `any_namespace` false. But the
winner's `__init__.py` calls `pkgutil.extend_path`, which rescans `sys.path`
for same-named directories and grafts them onto `__path__`.

rules_py cannot tell an extend_path package from a plain one -- nothing in the
wheel metadata distinguishes them -- so the loser's whole-wheel `.pth` fallback
has to stay. Dropping it makes `efirst` unimportable.
"""

from pathlib import Path
import sys

from collision_order import efirst, esecond

assert efirst.VALUE == "efirst", efirst.VALUE
assert esecond.VALUE == "esecond", esecond.VALUE

# The graft only works because the loser's site-packages is still reachable.
assert any(
    Path(entry).name == "site-packages"
    and "_extend_path_native_first.install" in Path(entry).parts
    for entry in sys.path
), sys.path
