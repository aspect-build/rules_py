"""Sanity check for the snapshot fixture: the colliding venv imports cleanly.

The real assertion lives in the pinned `.pth` snapshot (see the e2e
`write_source_files` registry); this just keeps the fixture honest by
exercising both wheels at runtime.
"""

import apkg
import bpkg
import shared

assert apkg.VALUE == "apkg"
assert bpkg.VALUE == "bpkg"
# One of the two `shared` contributors wins; we only care that it resolves.
assert shared.OWNER in ("a", "b")
