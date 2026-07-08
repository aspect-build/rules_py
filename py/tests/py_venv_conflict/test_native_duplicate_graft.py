from importlib.metadata import distributions
from importlib.util import find_spec
from pathlib import Path
import sys

from collision_order import first, graft_second


assert first.VALUE == "first", first.VALUE
assert find_spec("collision_order.graft_first") is None
assert graft_second.VALUE == "graft_second", graft_second.VALUE

fallbacks = [
    Path(entry)
    for entry in sys.path
    if Path(entry).name == "site-packages"
    and any(
        part.startswith("_native_duplicate_graft_") and part.endswith(".install")
        for part in Path(entry).parts
    )
]
assert len(fallbacks) == 1, fallbacks
assert "_native_duplicate_graft_second.install" in fallbacks[0].parts
summaries = [
    distribution.metadata["Summary"]
    for distribution in distributions()
    if distribution.metadata["Summary"] in {
        "_native_duplicate_graft_first",
        "_native_duplicate_graft_second",
    }
]
assert summaries == ["_native_duplicate_graft_second"], summaries
