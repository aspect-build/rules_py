"""debug-full provisions a Py_DEBUG 3.13 interpreter (ABI flag "d")."""

import sys


def main():
    assert sys.version_info[:2] == (3, 13), sys.version
    assert sys.abiflags == "d", "expected abiflags 'd', got %r" % sys.abiflags
    # sys.gettotalrefcount only exists in Py_DEBUG builds.
    assert hasattr(sys, "gettotalrefcount"), "expected a Py_DEBUG interpreter"
    print("OK debug-full:", sys.executable, sys.version)


if __name__ == "__main__":
    main()
