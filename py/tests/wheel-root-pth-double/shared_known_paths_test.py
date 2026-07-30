"""Two unknown-layout wheels must each reach sys.path exactly once.

`_format_imp` emits one `site.addsitedir(...)` line per unknown-layout wheel,
and each passes the `known_paths` set that the enclosing `site.addpackage` is
already maintaining, so N of them cost O(N) rather than O(N^2). Reusing a set
is what could go wrong: a stale one lets a directory be appended twice, and an
over-eager one makes a later `addsitedir` believe a directory was already
present and silently skip it.

The launcher processes the venv site-packages as a site dir twice (see
double_pth_test.py), so the whole `.pth` — every `addsitedir` line in it — runs
twice. Deduplication across those two passes is precisely what `known_paths`
is for, which makes this the case a reused set has to get right.

The tail of the test pins the emitted file's shape rather than its effect,
plus the two ways the reused set could be wrong: staleness against the plain
path entries interleaved with these lines, and the set not being in scope at
all.
"""

import os
import shutil
import site
import sys
import tempfile

WHEELS = ("pthtest_unknown_layout", "pthtest_unknown_layout_b")

# What every emitted `addsitedir` line must pass as `known_paths`: the live set
# owned by the enclosing `addpackage`, not one of our own. `exec` hands a .pth
# line that frame's locals as its own, so `vars()` reaches it.
KNOWN_PATHS_EXPR = 'vars().get("known_paths")'


def find_venv_pth() -> str:
    """The venv's own `.pth`. `os.walk` does not follow the site-packages
    symlinks out into runfiles, so this stays within the venv tree."""
    for root, _dirs, files in os.walk(sys.prefix):
        for name in sorted(files):
            if not name.endswith(".pth"):
                continue
            path = os.path.join(root, name)
            with open(path) as fh:
                if "site.addsitedir(" in fh.read():
                    return path
    raise SystemExit("no venv .pth calling site.addsitedir under {}".format(sys.prefix))


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
            "wheel-root .pth executions are asymmetric {} — the reused "
            "known_paths set made one addsitedir re-scan or skip".format(counts)
        )

    import apkg
    import bpkg

    if (apkg.VALUE, bpkg.VALUE) != ("apkg", "bpkg"):
        raise SystemExit("unknown-layout wheel packages did not import")


def check_pth_shape(lines: list[str]) -> list[str]:
    """Every addsitedir line reuses the caller's set.

    Dropping the reuse costs only startup time and is invisible from sys.path,
    so pin the expression rather than an effect.
    """
    add_lines = [i for i, ln in enumerate(lines) if "site.addsitedir(" in ln]
    if len(add_lines) < 2:
        raise SystemExit(
            "expected at least two addsitedir lines, got {}".format(len(add_lines))
        )

    unshared = [i + 1 for i in add_lines if KNOWN_PATHS_EXPR not in lines[i]]
    if unshared:
        raise SystemExit(
            "addsitedir lines {} do not pass `{}` — back to a per-line "
            "_init_pathinfo()".format(unshared, KNOWN_PATHS_EXPR)
        )
    return [lines[i] for i in add_lines]


def check_stale_set_regression() -> None:
    """A plain path entry landing between the addsitedir lines must be visible
    to them.

    `addpackage` adds plain lines to the set it owns. A set of our own would
    not see them, so a wheel-root `.pth` naming that same directory would
    append it a second time. Built here rather than assembled by the venv
    rules, because no fixture wheel ships a root `.pth` pointing back out at a
    venv import root.
    """
    root = tempfile.mkdtemp(prefix="rules-py-stale-")
    try:
        shared_dir = os.path.join(root, "shared_dir")
        wheel_sp = os.path.join(root, "wheel", "site-packages")
        os.makedirs(shared_dir)
        os.makedirs(wheel_sp)
        with open(os.path.join(wheel_sp, "w.pth"), "w") as fh:
            fh.write(os.path.relpath(shared_dir, wheel_sp) + "\n")

        sitedir = os.path.join(root, "sitedir")
        os.makedirs(sitedir)
        with open(os.path.join(sitedir, "venv.pth"), "w") as fh:
            fh.write(shared_dir + "\n")
            fh.write(
                "import os, sys, site; site.addsitedir({!r}, {})\n".format(
                    wheel_sp, KNOWN_PATHS_EXPR
                )
            )

        saved = list(sys.path)
        try:
            site.addpackage(sitedir, "venv.pth", None)
            hits = [p for p in sys.path if os.path.realpath(p) == os.path.realpath(shared_dir)]
        finally:
            sys.path[:] = saved
    finally:
        shutil.rmtree(root)

    if len(hits) != 1:
        raise SystemExit(
            "plain path entry landed on sys.path {} times — the addsitedir "
            "line is reusing a set that is stale against it".format(len(hits))
        )


def check_foreign_caller_degrades(add_line: str) -> None:
    """`addpackage` abandons the rest of the file on the first line that
    raises, so an `addsitedir` line must be total when it runs anywhere else —
    no `known_paths` in scope, `.get` yields None, and `addsitedir` rebuilds
    the set itself, still finding the directory on sys.path and appending
    nothing. A bare `known_paths` reference would raise here instead."""
    before = len(sys.path)
    try:
        exec(add_line, {})
    except Exception as exc:
        raise SystemExit("addsitedir line raised outside addpackage: {!r}".format(exc))

    readded = [p for p in sys.path[before:] if p.endswith("site-packages")]
    if readded:
        raise SystemExit("addsitedir re-appended {} outside addpackage".format(readded))


def main() -> None:
    check_sys_path()

    with open(find_venv_pth()) as fh:
        lines = [ln for ln in fh.read().splitlines() if ln.strip()]

    add_lines = check_pth_shape(lines)
    check_stale_set_regression()
    # Last: re-running an addsitedir line re-fires that wheel's root `.pth`.
    check_foreign_caller_degrades(add_lines[0])


if __name__ == "__main__":
    main()
