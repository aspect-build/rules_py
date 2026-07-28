"""Two unknown-layout wheels must each reach sys.path exactly once.

`_format_imp` emits one `site.addsitedir(...)` line per unknown-layout wheel,
and those lines share a single `known_paths` set stashed on the `site` module
by `_KNOWN_PATHS_PROLOGUE`, so N of them cost O(N) rather than O(N^2). Sharing
that set is what could go wrong: a stale set would let a directory be appended
twice, and an over-eager one would make the second `addsitedir` believe a
directory was already present and silently skip it.

The launcher processes the venv site-packages as a site dir twice (see
double_pth_test.py), so the whole `.pth` — every `addsitedir` line in it — runs
twice. Deduplication across those two passes is precisely what `known_paths`
is for, which makes this the case a shared set has to get right.

The tail of the test pins the emitted file's shape rather than its effect: one
prologue, ahead of the lines that read it, and an `addsitedir` line that still
behaves when the stash is missing.
"""

import os
import sys

WHEELS = ("pthtest_unknown_layout", "pthtest_unknown_layout_b")

STASH = "_aspect_rules_py_known_paths"


def find_venv_pth() -> str:
    """The venv's own `.pth`. `os.walk` does not follow the site-packages
    symlinks out into runfiles, so this stays within the venv tree."""
    for root, _dirs, files in os.walk(sys.prefix):
        for name in sorted(files):
            if not name.endswith(".pth"):
                continue
            path = os.path.join(root, name)
            with open(path) as fh:
                if STASH in fh.read():
                    return path
    raise SystemExit("no venv .pth referencing {} under {}".format(STASH, sys.prefix))


def check_sys_path() -> None:
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


def check_pth_shape(lines: list[str]) -> list[str]:
    """One prologue for the whole file, ahead of every line that reads it."""
    prologues = [i for i, ln in enumerate(lines) if ln.startswith("import site;")]
    add_lines = [i for i, ln in enumerate(lines) if "site.addsitedir(" in ln]

    if len(prologues) != 1:
        raise SystemExit(
            "expected exactly one known_paths prologue, got {}".format(len(prologues))
        )
    if len(add_lines) < 2:
        raise SystemExit(
            "expected at least two addsitedir lines, got {}".format(len(add_lines))
        )
    if prologues[0] > add_lines[0]:
        raise SystemExit(
            "prologue on line {} follows an addsitedir line on {}".format(
                prologues[0] + 1, add_lines[0] + 1
            )
        )

    # Losing the shared set costs only startup time, so nothing observable
    # from sys.path catches it. Pin the reference instead.
    unshared = [i + 1 for i in add_lines if STASH not in lines[i]]
    if unshared:
        raise SystemExit(
            "addsitedir lines {} do not read {} — back to a per-line "
            "_init_pathinfo()".format(unshared, STASH)
        )
    return [lines[i] for i in add_lines]


def check_missing_stash_degrades(add_line: str) -> None:
    """`addpackage` abandons the rest of the file on the first line that
    raises, so an `addsitedir` line must be total with no stash present. It
    falls back to rebuilding `known_paths`, which still finds the directory
    already on sys.path and appends nothing."""
    site = sys.modules["site"]
    saved = site.__dict__.pop(STASH, None)
    before = len(sys.path)
    try:
        exec(add_line, {})
    except Exception as exc:
        raise SystemExit(
            "addsitedir line raised without the {} stash: {!r}".format(STASH, exc)
        )
    finally:
        if saved is not None:
            setattr(site, STASH, saved)

    readded = [p for p in sys.path[before:] if p.endswith("site-packages")]
    if readded:
        raise SystemExit("addsitedir re-appended {} after losing the stash".format(readded))


def main() -> None:
    check_sys_path()

    with open(find_venv_pth()) as fh:
        lines = [ln for ln in fh.read().splitlines() if ln.strip()]

    add_lines = check_pth_shape(lines)
    # Last: re-running an addsitedir line re-fires that wheel's root `.pth`.
    check_missing_stash_degrades(add_lines[0])


if __name__ == "__main__":
    main()
