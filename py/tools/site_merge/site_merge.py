"""Site-packages directory merger for aspect_rules_py venv assembly.

Physically merge one regular-package subtree contributed by multiple wheels
into a single output directory, reproducing a flat wheel installation.

This handles regular packages that span wheels, PEP 420 namespaces, and tools
that inspect one concrete site-packages tree without executing `.pth` files.

Invoked by Bazel as::

    <exec_python> site_merge.py --into <dir> [--collision-policy P] --src <dir> [--src <dir> ...]

Each ``--src`` is one wheel's copy of the package subtree, in
installation order: on file-level conflicts the last wheel providing a
path wins. Every requested source must exist; otherwise the venv would
silently omit a directory that analysis marked as fully represented by
the merged output.
"""

import argparse
import filecmp
import os
import shutil
import stat
from pathlib import Path


def _remove(path):
    """Remove copied Bazel inputs, including read-only files on Windows."""

    def retry_readonly(function, candidate, exc_info):
        error = exc_info[1]
        if not isinstance(error, PermissionError):
            raise error
        candidate = Path(candidate)
        candidate.chmod(candidate.stat().st_mode | stat.S_IWRITE)
        function(candidate)

    if path.is_dir():
        shutil.rmtree(path, onerror=retry_readonly)
        return
    try:
        path.unlink()
    except PermissionError:
        path.chmod(path.stat().st_mode | stat.S_IWRITE)
        path.unlink()


def merge(into, sources):
    missing = [src for src in sources if not src.is_dir()]
    if missing:
        raise FileNotFoundError(
            "Missing package merge sources: {}".format(", ".join(map(str, missing)))
        )

    into.mkdir(parents=True, exist_ok=True)
    owners = {}
    conflicts = []

    for src in sources:
        for root, dirs, files in os.walk(src):
            rel_root = Path(root).relative_to(src)
            kept_dirs = []
            for d in sorted(dirs):
                rel = rel_root / d
                dest = into / rel
                prior = owners.get(rel)
                if dest.exists() and not dest.is_dir():
                    conflicts.append((rel, prior, src))
                    _remove(dest)
                if not dest.exists():
                    dest.mkdir(parents=True)
                owners[rel] = src
                kept_dirs.append(d)
            dirs[:] = kept_dirs
            for f in sorted(files):
                rel = rel_root / f
                dest = into / rel
                src_file = Path(root) / f
                prior = owners.get(rel)
                if dest.is_dir():
                    conflicts.append((rel, prior, src))
                    _remove(dest)
                if dest.exists():
                    # Byte-identical duplicates (e.g.
                    # an empty __init__.py or py.typed shipped by both
                    # wheels) are benign and not reported.
                    if filecmp.cmp(str(src_file), str(dest), shallow=False):
                        owners[rel] = src
                        continue
                    conflicts.append((rel, prior, src))
                    # Bazel inputs are commonly read-only, and shutil.copy
                    # preserves that mode. Unlink before installing the later
                    # winner so it does not need write access to the old file.
                    _remove(dest)
                shutil.copy(str(src_file), str(dest))
                owners[rel] = src

    return conflicts


def main():
    os.umask(0o022)

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--into", required=True, type=Path)
    ap.add_argument("--src", dest="sources", action="append", default=[], type=Path)
    ap.add_argument(
        "--collision-policy",
        default="warning",
        choices=["error", "warning", "ignore"],
    )
    args = ap.parse_args()

    conflicts = merge(args.into, args.sources)

    if conflicts and args.collision_policy != "ignore":
        for rel, winner, loser in conflicts:
            print(
                "Package collision while merging {}: `{}` is provided by both {} and {}.".format(
                    args.into, rel, winner, loser
                )
            )
        if args.collision_policy == "error":
            raise SystemExit(
                'Set `package_collisions = "warning"` or "ignore" to downgrade.'
            )


if __name__ == "__main__":
    main()
