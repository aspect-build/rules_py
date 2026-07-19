"""install_only_stripped provisions a regular (non-debug) 3.13 interpreter."""

import sys


def main() -> None:
    assert sys.version_info[:2] == (3, 13), sys.version
    # A stripped install_only build is a regular build: the debug-only
    # sys.gettotalrefcount must be absent and the ABI must carry no flags.
    assert not hasattr(sys, "gettotalrefcount"), "expected a non-debug interpreter"
    assert sys.abiflags == "", "expected empty abiflags, got %r" % sys.abiflags
    print("OK install_only_stripped:", sys.executable, sys.version)


if __name__ == "__main__":
    main()
