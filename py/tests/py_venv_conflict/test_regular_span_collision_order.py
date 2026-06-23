import importlib
import sys

from other import from_graft, from_other


assert from_graft.VALUE == "graft", from_graft.VALUE
assert from_other.VALUE == "other", from_other.VALUE

if sys.argv[1] == "regular":
    from mixed.root import collision

    assert collision.VALUE == "regular", (
        f"regular atomic owner lost to {collision.VALUE!r}"
    )
else:
    from mixed import sibling

    assert sibling.VALUE == "graft", (
        f"namespace atomic owner lost to {sibling.VALUE!r}"
    )
    try:
        importlib.import_module("mixed.root.__init__")
    except ModuleNotFoundError:
        pass
    else:
        raise AssertionError("mixed regular collision loser leaked through .pth")
