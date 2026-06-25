from mixed import sibling
from mixed.root import final_unique, graft_unique, regular_unique, shared
from other import from_final, from_other


assert shared.VALUE == "shared", shared.VALUE
assert regular_unique.VALUE == "regular", regular_unique.VALUE
assert final_unique.VALUE == "final", final_unique.VALUE
assert graft_unique.VALUE == "graft", graft_unique.VALUE
assert sibling.VALUE == "sibling", sibling.VALUE
assert from_final.VALUE == "final", from_final.VALUE
assert from_other.VALUE == "other", from_other.VALUE
