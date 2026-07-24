"""Regression for https://github.com/aspect-build/rules_py/issues/1366.

A wheel may ship data files under the PEP 427 `.data/data/` scheme, which
`pip`/`rules_python` install into `sys.prefix/share/...`. Tools such as
`jupyter_core` (and therefore nbconvert, Jupyter, ...) discover resources
by walking `<sys.prefix>/share/...`, so venv assembly must project the
wheel's data tree into the prefix alongside site-packages and `bin/`.

This test depends on a hand-built wheel carrying
`sharedata-1.0.data/data/share/sharedata/hello.txt` and asserts the file is
reachable via `sys.prefix/share`, exactly as pip would install it.
"""

import os
import sys

from datapkg import ETC_FILE, ROOT_FILE, SHARE_FILE


def main() -> None:
    print(f"sys.prefix={sys.prefix}")
    print(f"looking for wheel data file at {SHARE_FILE}")

    if not os.path.exists(SHARE_FILE):
        print(
            "FAIL: wheel data file not found under sys.prefix/share. Wheel "
            "`.data/data/share/...` files are installed into the wheel tree "
            "but never projected into the venv prefix, so tools that discover "
            "resources via sys.prefix/share (jupyter_core, nbconvert, ...) "
            "cannot find them."
        )
        sys.exit(1)

    with open(SHARE_FILE, encoding="utf-8") as fh:
        contents = fh.read().strip()
    print(f"found: {contents!r}")

    if contents != "template-data":
        print(f"FAIL: unexpected data-file contents: {contents!r}")
        sys.exit(1)

    # The data scheme is prefix-relative, not share/-relative: a second prefix
    # root and a file at the prefix itself must project too. `toplevel.txt` is
    # the zero-separator case for the symlink escape arithmetic.
    for path, expected in ((ETC_FILE, "etc-config"), (ROOT_FILE, "prefix-root")):
        if not os.path.exists(path):
            print(f"FAIL: wheel data file not projected into the prefix: {path}")
            sys.exit(1)
        with open(path, encoding="utf-8") as fh:
            found = fh.read().strip()
        if found != expected:
            print(f"FAIL: {path} contains {found!r}, expected {expected!r}")
            sys.exit(1)
        print(f"found: {path} -> {found!r}")

    print("PASS: wheel data files are discoverable under sys.prefix.")


if __name__ == "__main__":
    main()
