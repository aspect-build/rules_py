"""Regression for regular-first top-level native namespace collisions."""

from importlib.util import find_spec
from pathlib import Path
import sys
import sysconfig

import google


site_packages = Path(sysconfig.get_paths()["purelib"])
projected_init = site_packages / "google" / "__init__.py"
runtime_init = Path(google.__file__)

assert projected_init.is_file(), projected_init
assert runtime_init.name == "__init__.py", runtime_init
assert projected_init.samefile(runtime_init), (
    projected_init.resolve(),
    runtime_init.resolve(),
)
assert find_spec("google.protobuf") is None

protobuf_fallbacks = [
    Path(entry)
    for entry in sys.path
    if Path(entry).name == "site-packages"
    and any(
        candidate.suffix in (".so", ".pyd")
        for candidate in (Path(entry) / "google" / "_upb").glob("_message.*")
    )
]
assert protobuf_fallbacks, sys.path
