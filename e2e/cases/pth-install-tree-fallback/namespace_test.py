"""An entryless PEP 420 namespace must still union across both wheels.

Neither wheel declares `namespace_entries`, so venv assembly has nothing to
project per-entry and both wheel roots have to stay on the `.pth` fallback.
If either were dropped, only one contributor's module would import.
"""

import cpkg
import dpkg
import nspkg.mod_c
import nspkg.mod_d

assert cpkg.VALUE == "cpkg"
assert dpkg.VALUE == "dpkg"
assert nspkg.mod_c.VALUE == "ns_c"
assert nspkg.mod_d.VALUE == "ns_d"
