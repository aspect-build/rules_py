"""A complete-layout wheel reaching _format_imp must not rescan root .pth.

The hazard: if `_format_imp` uses `site.addsitedir()` on a wheel with a
complete immediate layout, its root `.pth` files were already routed through
collision resolution and may be projected into the venv. Site startup then
executes the projected copy before `addsitedir()` executes the original.

Setup: two `py_unpacked_wheel`s, each emitting `PyWheelsInfo` (they set
`top_levels`), each carrying a distinct root `.pth` that appends a unique
sentinel to `sys.path`. Both wheels claim the top-level `shared`, so one
of them loses that collision and is no longer "fully covered" by direct
per-top-level symlinks — the loser is routed through `_format_imp`'s
site-packages branch. The winner keeps a plain projected layout.

What we assert: each wheel's root `.pth` must fire the SAME number of
times, regardless of which one lost the collision. We do not assert an
absolute count of one: rules_py's launcher processes the venv
site-packages as a site dir twice, so every *projected* root `.pth`
already fires twice — a pre-existing, symmetric baseline. The hazard is
asymmetric: if only the collision loser, on the `addsitedir` fallback,
gets its wheel root re-scanned, its sentinel lands extra times (4 vs the
winner's 2). Asserting symmetry isolates that regression and is
independent of the launcher's per-site-dir scan count and of which wheel
happens to lose.

A complete-layout wheel routed through `_format_imp` must emit a plain path
entry, not `site.addsitedir`, so its root `.pth` count matches a wheel that
stayed on the direct-symlink path.
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
            f"({SENTINEL_A}={count_a}, {SENTINEL_B}={count_b}). The collision "
            "loser was routed through site.addsitedir(), which re-scanned its "
            "wheel root and re-executed a root .pth already projected into the "
            "venv site-packages. A complete-layout wheel reaching _format_imp "
            "must use a plain path entry, not addsitedir."
        )
        sys.exit(1)

    print("PASS: both wheel-root .pth files executed the same number of times.")


if __name__ == "__main__":
    main()
