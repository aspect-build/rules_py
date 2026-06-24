from mixed import sibling
from mixed.root import collision, final_unique, graft_unique
from other import from_final, from_other


assert collision.VALUE == "final", collision.VALUE
assert final_unique.VALUE == "final", final_unique.VALUE
assert graft_unique.VALUE == "graft", graft_unique.VALUE
assert sibling.VALUE == "final", sibling.VALUE
assert from_final.VALUE == "final", from_final.VALUE
assert from_other.VALUE == "other", from_other.VALUE
