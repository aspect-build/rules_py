import sys

from other import from_graft, from_other


assert from_graft.VALUE == "graft", from_graft.VALUE
assert from_other.VALUE == "other", from_other.VALUE

if sys.argv[1] == "merge":
    from mixed.root import collision

    assert collision.VALUE == "graft", (
        f"later physical merge input lost to {collision.VALUE!r}"
    )
else:
    from mixed import sibling

    assert sibling.VALUE == "graft", (
        f"later sibling namespace claimant lost to {sibling.VALUE!r}"
    )
