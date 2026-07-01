from importlib.util import find_spec
from pathlib import Path
import sys

from collision_order import first


assert first.VALUE == "first", first.VALUE
assert find_spec("collision_order.second") is None
assert any(
    Path(entry).name == "site-packages"
    and "_native_namespace_second.install" in Path(entry).parts
    for entry in sys.path
), sys.path
venv_site_packages = next(
    Path(entry)
    for entry in sys.path
    if Path(entry).name == "site-packages" and Path(entry).is_relative_to(sys.prefix)
)
venv_top = venv_site_packages / "collision_order"
assert (venv_top / "first.py").is_file(), venv_top
projected_top = venv_top.resolve()
runtime_top = Path(first.__file__).resolve().parent
owner_install = "_native_namespace_regular_first.install"
assert owner_install in projected_top.parts, projected_top
assert owner_install in runtime_top.parts, runtime_top
assert (
    projected_top.parts[projected_top.parts.index(owner_install) :]
    == runtime_top.parts[runtime_top.parts.index(owner_install) :]
), (
    projected_top,
    runtime_top,
)
