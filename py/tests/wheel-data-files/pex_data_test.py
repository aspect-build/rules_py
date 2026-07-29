"""PEX counterpart to `share_data_test.py`.

`py_pex_binary` packages wheel install trees as pex `--dependency` entries,
which cover only site-packages, so the PEP 427 `.data/data/` files need to ship
as sources. There is no `sys.prefix` analogue inside a PEX — a zipapp runs under
the ambient interpreter — so the files are reachable at the runfiles path they
occupy outside the PEX, and this asserts they are not silently dropped.
"""

import os
import sys

import runfiles

RLOCATIONS = {
    "_main/py/tests/wheel-data-files/sharedata/share/sharedata/hello.txt": "template-data",
    "_main/py/tests/wheel-data-files/sharedata/etc/sharedata/config.json": "etc-config",
    "_main/py/tests/wheel-data-files/sharedata/toplevel.txt": "prefix-root",
}


def main() -> None:
    r = runfiles.Create()
    found = []
    for rlocation, expected in RLOCATIONS.items():
        path = r.Rlocation(rlocation)
        if path is None or not os.path.exists(path):
            print(f"FAIL: wheel data file not packaged into the PEX: {rlocation}")
            sys.exit(1)
        with open(path, encoding="utf-8") as fh:
            contents = fh.read().strip()
        if contents != expected:
            print(f"FAIL: {rlocation} contains {contents!r}, expected {expected!r}")
            sys.exit(1)
        found.append(contents)

    print("PEX_DATA_FILES=" + ",".join(found))


if __name__ == "__main__":
    main()
