"""Site-packages subtree merger for aspect_rules_py venv assembly.

Physically merges one package directory contributed by multiple wheels
into a single output directory — the shape a flat `pip install` into one
site-packages would produce.

Needed when a *regular* package (one with an `__init__.py`) spans
wheels: e.g. azure-core owns `azure/core/` while
azure-core-tracing-opentelemetry installs
`azure/core/tracing/ext/opentelemetry_span/` into that same tree.
Python locks a regular package's `__path__` to the first directory
found on `sys.path`, so unlike PEP 420 namespace portions the
contributions cannot be merged at import time — they have to be merged
on disk.

Invoked by Bazel as::

    <exec_python> site_merge.py --into <dir> [--collision-policy P] --src <dir> [--src <dir> ...]

Each ``--src`` is one wheel's copy of the package directory, in
priority order: on file-level conflicts the first wheel providing a
path wins. Sources that don't exist are skipped (platform wheels for
other architectures may not ship the directory).
"""

import argparse
import filecmp
import os
import shutil
from pathlib import Path


def merge(into, sources):
    into.mkdir(parents=True, exist_ok=True)
    owners = {}
    conflicts = []

    for src in sources:
        if not src.is_dir():
            continue
        for root, dirs, files in os.walk(src):
            rel_root = Path(root).relative_to(src)
            for d in sorted(dirs):
                dest_dir = into / rel_root / d
                if dest_dir.exists() and not dest_dir.is_dir():
                    raise ValueError(
                        "Type conflict at {}: was a file (from {}), now a directory (from {}).".format(
                            rel_root / d, owners.get(rel_root / d, "unknown"), src
                        )
                    )
                dest_dir.mkdir(parents=True, exist_ok=True)
            for f in sorted(files):
                rel = rel_root / f
                dest = into / rel
                src_file = Path(root) / f
                if dest.is_dir():
                    raise ValueError(
                        "Type conflict at {}: was a directory, now a file (from {}).".format(
                            rel, src
                        )
                    )
                prior = owners.get(rel)
                if prior is not None:
                    # First wheel wins; byte-identical duplicates (e.g.
                    # an empty __init__.py or py.typed shipped by both
                    # wheels) are benign and not reported.
                    if not filecmp.cmp(str(src_file), str(dest), shallow=False):
                        conflicts.append((rel, prior, src))
                    continue
                shutil.copy(str(src_file), str(dest))
                owners[rel] = src

    return conflicts


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--into", required=True, type=Path)
    ap.add_argument("--src", dest="sources", action="append", default=[], type=Path)
    ap.add_argument(
        "--collision-policy",
        default="warning",
        choices=["error", "warning", "ignore"],
    )
    args = ap.parse_args()

    try:
        conflicts = merge(args.into, args.sources)
    except ValueError as exc:
        if args.collision_policy == "error":
            raise SystemExit(str(exc))
        print(str(exc))
        conflicts = []

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
