from importlib.util import find_spec
from pathlib import Path
import sys

from mixed.native import regular as native_regular
from mixed.pure import graft, regular as pure_regular


assert native_regular.VALUE == "regular", native_regular.VALUE
assert find_spec("mixed.native.graft") is None
venv_site_packages = next(
    Path(entry)
    for entry in sys.path
    if Path(entry).name == "site-packages" and Path(entry).is_relative_to(sys.prefix)
)
venv_native = venv_site_packages / "mixed" / "native"
assert (venv_native / "regular.py").is_file(), venv_native
projected_native = venv_native.resolve()
runtime_native = Path(native_regular.__file__).resolve().parent
assert "native_regular.install" in projected_native.parts, projected_native
assert "native_regular.install" in runtime_native.parts, runtime_native
assert (
    projected_native.parts[projected_native.parts.index("native_regular.install") :]
    == runtime_native.parts[runtime_native.parts.index("native_regular.install") :]
), (
    projected_native,
    runtime_native,
)
assert graft.VALUE == "graft", graft.VALUE
assert pure_regular.VALUE == "regular", pure_regular.VALUE
