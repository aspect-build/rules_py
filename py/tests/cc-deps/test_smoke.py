import sys

import example_library

assert example_library.add(2, 3) == 5, "native extension returned the wrong sum"
assert example_library.version_hex() == sys.hexversion, (
    f"extension headers report {example_library.version_hex():#x}, "
    f"but the runtime reports {sys.hexversion:#x}"
)
