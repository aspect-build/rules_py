"""The unfiltered shared graph and direct requirement must still install A."""

import sys

import self_exclusion_a
import self_exclusion_c


assert self_exclusion_a.VALUE == "built with b and c"
assert self_exclusion_c.VALUE == "c"

if sys.argv[1] == "shared":
    import self_exclusion_b

    assert self_exclusion_b.VALUE == "b"
