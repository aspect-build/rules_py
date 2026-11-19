"""A first-party module named like a stdlib module this interpreter lacks."""

import sys

if sys.platform != "win32":
    import winsound

    assert winsound.SHIM
