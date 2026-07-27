"""Two unknown-layout wheels must each reach sys.path exactly once.

`_format_imp` emits one `site.addsitedir(...)` line per unknown-layout wheel,
and those lines thread a single `known_paths` set through the `site` module so
N of them cost O(N) rather than O(N^2). Sharing that set is what could go
wrong: a stale set would let a directory be appended twice, and an over-eager
one would make the second `addsitedir` believe a directory was already present
and silently skip it.

The launcher processes the venv site-packages as a site dir twice (see
double_pth_test.py), so the whole `.pth` — every `addsitedir` line in it — runs
twice. Deduplication across those two passes is precisely what `known_paths`
is for, which makes this the case a shared set has to get right.
"""

import sys

WHEELS = ("pthtest_unknown_layout", "pthtest_unknown_layout_b")


def main() -> None:
    site_packages = [p for p in sys.path if p.endswith("site-packages")]

    for name in WHEELS:
        owned = [p for p in site_packages if "/{}/".format(name) in p]
        if len(owned) != 1:
            raise SystemExit(
                "expected exactly one sys.path entry for {}, got {}".format(name, owned)
            )

    if len(site_packages) != len(set(site_packages)):
        duplicates = sorted({p for p in site_packages if site_packages.count(p) > 1})
        raise SystemExit("duplicate site-packages on sys.path: {}".format(duplicates))

    # Both wheel-root `.pth` shims must still fire — `addsitedir` runs them as
    # it scans each directory it appends. Counts are asserted symmetric rather
    # than absolute, for the same reason double_pth_test.py does: the launcher's
    # per-site-dir scan count is a pre-existing, uniform multiplier.
    counts = [sys.path.count(s) for s in ("rules_py_pth_sentinel_a", "rules_py_pth_sentinel_b")]
    if counts[0] < 1 or counts[1] < 1:
        raise SystemExit("a wheel root .pth did not execute: {}".format(counts))
    if counts[0] != counts[1]:
        raise SystemExit(
            "wheel-root .pth executions are asymmetric {} — the shared "
            "known_paths set made one addsitedir re-scan or skip".format(counts)
        )

    import apkg
    import bpkg

    if (apkg.VALUE, bpkg.VALUE) != ("apkg", "bpkg"):
        raise SystemExit("unknown-layout wheel packages did not import")


if __name__ == "__main__":
    main()
