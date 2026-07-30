"""A wheel data file may not take over a path the venv itself owns.

PEP 427 puts no restriction on where a `.data/data/` file lands in the
install prefix, so a wheel can name `bin/python`, `pyvenv.cfg`, a console
script, or anything under site-packages. Every one of those is already
declared by venv assembly: projecting the data file too would declare the
same output twice, which Bazel rejects at analysis time — before any
`package_collisions` policy can apply.

The fixture wheel claims all four, plus one ordinary `share/` path. This
test running at all proves assembly succeeded; the assertions prove the
venv's own artifacts survived intact and the unreserved data file still
projects.
"""

import os
import sys

from respkg import (
    BIN_PYTHON,
    CONSOLE_SCRIPT,
    KEPT_FILE,
    LIB_INJECTED,
    PYVENV_CFG,
    SITE_PACKAGES_INJECTED,
)

HIJACKED = "HIJACKED"


def _read(path: str) -> str:
    with open(path, "rb") as fh:
        return fh.read(64).decode("utf-8", "replace")


def _assert_not_hijacked(label: str, path: str) -> None:
    if not os.path.exists(path):
        print(f"FAIL: {label} missing from the venv: {path}")
        sys.exit(1)
    if HIJACKED in _read(path):
        print(f"FAIL: wheel data file overwrote the venv's own {label}: {path}")
        sys.exit(1)
    print(f"ok: {label} intact")


def main() -> None:
    _assert_not_hijacked("interpreter symlink", BIN_PYTHON)
    _assert_not_hijacked("pyvenv.cfg", PYVENV_CFG)
    _assert_not_hijacked("console script", CONSOLE_SCRIPT)

    if os.path.exists(SITE_PACKAGES_INJECTED):
        print(
            "FAIL: wheel data file projected into venv site-packages: "
            f"{SITE_PACKAGES_INJECTED}"
        )
        sys.exit(1)
    print("ok: site-packages left to wheel projection")

    if os.path.exists(LIB_INJECTED):
        print(f"FAIL: wheel data file projected into venv lib/: {LIB_INJECTED}")
        sys.exit(1)
    print("ok: lib/ left to the venv")

    if not os.path.exists(KEPT_FILE):
        print(f"FAIL: unreserved data file was not projected: {KEPT_FILE}")
        sys.exit(1)
    with open(KEPT_FILE, encoding="utf-8") as fh:
        contents = fh.read().strip()
    if contents != "reserved-arm-kept":
        print(f"FAIL: {KEPT_FILE} contains {contents!r}")
        sys.exit(1)
    print("ok: unreserved data file projected")

    print("PASS: venv-owned prefix paths are reserved from wheel data files.")


if __name__ == "__main__":
    main()
