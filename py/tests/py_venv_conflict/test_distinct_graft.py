from importlib.metadata import distributions
from pathlib import Path
import sys

from collision_order import dfirst, dsecond


assert dfirst.VALUE == "dfirst", dfirst.VALUE

# The losing native claimant is a distinct distribution, so it must stay on
# the .pth fallback; the winner's pkgutil.extend_path __init__ reaches its
# graft from there.
assert dsecond.VALUE == "dsecond", dsecond.VALUE
assert any(
    Path(entry).name == "site-packages"
    and "_distinct_graft_native.install" in Path(entry).parts
    for entry in sys.path
), sys.path

# All three distributions carry distinct metadata; every one must remain
# discoverable.
summaries = {
    distribution.metadata["Summary"]
    for distribution in distributions()
    if distribution.metadata["Summary"].startswith("_distinct_graft_")
}
assert summaries == {
    "_distinct_graft_regular",
    "_distinct_graft_native",
    "_distinct_graft_third",
}, summaries
