"""Compatible directory claimants must not duplicate root `.pth` effects.

Two installed wheels contribute compatible contents to `shared` and distinct
root `.pth` files. Directory union accounts for both wheel roots, so each
projected `.pth` file must execute the same number of times without an
additional `site.addsitedir` scan.
"""

import sys

SENTINEL_A = "rules_py_pth_sentinel_a"
SENTINEL_B = "rules_py_pth_sentinel_b"


def main():
    count_a = sys.path.count(SENTINEL_A)
    count_b = sys.path.count(SENTINEL_B)
    print(f"{SENTINEL_A}: {count_a} time(s) on sys.path")
    print(f"{SENTINEL_B}: {count_b} time(s) on sys.path")

    # Sanity: both wheels are importable and the `shared` collision resolved.
    import apkg
    import bpkg
    import shared

    print(f"imported apkg={apkg.VALUE} bpkg={bpkg.VALUE} shared-owner={shared.OWNER}")

    if count_a < 1 or count_b < 1:
        print("FAIL: a wheel-root .pth did not execute at all.")
        sys.exit(1)

    if count_a != count_b:
        print(
            "FAIL: wheel-root .pth executions are asymmetric "
            f"({SENTINEL_A}={count_a}, {SENTINEL_B}={count_b}). A wheel root "
            "was scanned in addition to its projected .pth file."
        )
        sys.exit(1)

    print("PASS: both wheel-root .pth files executed the same number of times.")


if __name__ == "__main__":
    main()
