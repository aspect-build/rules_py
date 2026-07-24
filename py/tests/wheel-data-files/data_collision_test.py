"""Two wheels ship data files under the PEP 427 `.data/data/` scheme; one path
(`share/collide/common.txt`) is claimed by BOTH, the rest are disjoint.

Per-file projection must:
  * union the disjoint files (`share/a/only_a.txt`, `share/b/only_b.txt`), and
  * resolve the colliding path to a single file (last distinct wheel wins),
    under `package_collisions = "warning"` (no build failure).
"""

import os
import sys

SHARE = os.path.join(sys.prefix, "share")
ONLY_A = os.path.join(SHARE, "a", "only_a.txt")
ONLY_B = os.path.join(SHARE, "b", "only_b.txt")
COMMON = os.path.join(SHARE, "collide", "common.txt")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


def main() -> None:
    for path in (ONLY_A, ONLY_B, COMMON):
        if not os.path.isfile(path):
            raise SystemExit(f"FAIL: expected data file missing: {path}")

    # Disjoint contributions from both wheels must both survive the merge.
    assert read(ONLY_A) == "only-a", read(ONLY_A)
    assert read(ONLY_B) == "only-b", read(ONLY_B)

    # The colliding path resolves to exactly one wheel's file — last distinct
    # claimant wins (wheel b is the later dep), matching pip's overwrite.
    common = read(COMMON)
    print(f"share/collide/common.txt -> {common!r}")
    if common != "from-b":
        raise SystemExit(
            f"FAIL: colliding data file resolved to {common!r}, expected the "
            "last distinct claimant 'from-b'."
        )

    print("PASS: disjoint data files unioned; colliding path resolved last-wins.")


if __name__ == "__main__":
    main()
