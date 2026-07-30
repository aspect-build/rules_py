"""PEX counterpart to `reserved_paths_test.py`.

Wheel data files landing in a venv-owned prefix root (`bin/`, `lib/`,
`pyvenv.cfg`) are dropped by venv assembly. `py_pex_binary` forwards data files
as pex `--source` entries to escape the wheel-tree exclusion, so it has to apply
the same reservation — otherwise the PEX ships files its venv counterpart
refuses, and the two disagree about what the wheel installed.

Asserts on the `--source` copies only, at the runfiles path they occupy outside
the PEX. `lib/<ver>/site-packages/injected.py` is separately reachable as
`.deps/reserveddata-1.0/injected.py`, because the unpacker routes that data path
into the very site-packages directory pex packages as a `--dependency`; that is
long-standing behaviour and not what this guards.
"""

import os
import sys

import runfiles

TREE = "_main/py/tests/wheel-data-files/reserveddata/"

# Reserved: claimed by the fixture wheel's `.data/data/`, dropped by the venv,
# so absent from the PEX's source tree too.
RESERVED = (
    "bin/python",
    "bin/reserved-cli",
    "pyvenv.cfg",
    "lib/libextra.so",
    "lib/python3.12/site-packages/injected.py",
)

# Unreserved: an ordinary prefix data file, projected by the venv and packaged
# here. Pins that the filter rejects only the reserved roots.
KEPT = "share/reserveddata/kept.txt"


def main() -> None:
    r = runfiles.Create()
    leaked = []
    for relative in RESERVED:
        path = r.Rlocation(TREE + relative)
        if path is not None and os.path.exists(path):
            leaked.append(relative)

    if leaked:
        print(
            "FAIL: wheel data files in venv-owned prefix roots were packaged "
            f"into the PEX: {leaked}. venv assembly drops these, so the PEX "
            "must not carry them."
        )
        sys.exit(1)

    kept = r.Rlocation(TREE + KEPT)
    if kept is None or not os.path.exists(kept):
        print(f"FAIL: unreserved data file missing from the PEX: {KEPT}")
        sys.exit(1)
    with open(kept, encoding="utf-8") as fh:
        contents = fh.read().strip()
    if contents != "reserved-arm-kept":
        print(f"FAIL: {KEPT} contains {contents!r}")
        sys.exit(1)

    print("PEX_RESERVED=dropped-" + str(len(RESERVED)) + ",kept-1")


if __name__ == "__main__":
    main()
