"""Site-packages subtree merger for aspect_rules_py venv assembly.

Physically merges one package directory contributed by multiple wheels
into a single output directory — the shape a flat `pip install` into one
site-packages would produce.

Needed when a *regular* package (one with an `__init__.py`) spans
wheels or multiple wheels claim the same top-level package directory.
For example, azure-core owns `azure/core/` while
azure-core-tracing-opentelemetry installs
`azure/core/tracing/ext/opentelemetry_span/` into that same tree.
Python locks a regular package's `__path__` to the first directory
found on `sys.path`, so unlike PEP 420 namespace portions the
contributions cannot be merged at import time — they have to be merged
on disk.

Invoked by Bazel as::

    <exec_python> site_merge.py --into <dir> [--collision-policy P] --src <dir> [--src <dir> ...]

Each ``--src`` is one wheel's copy of the package directory, in overlay
order: on conflicts the later wheel overlays the earlier one. Sources
that don't exist are skipped (platform wheels for other architectures
may not ship the directory).
"""

import argparse
import filecmp
import os
import shutil
import stat
import sys
from pathlib import Path


def _remove(path):
    """Remove an output copied from a potentially read-only input."""

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
    into.mkdir(parents=True, exist_ok=True)
    owners = {}
    conflicts = []

    for src in sources:
        if not src.is_dir():
            continue
        for root, dirs, files in os.walk(src):
            dirs.sort()
            files.sort()
            rel_root = Path(root).relative_to(src)
            for d in dirs:
                rel = rel_root / d
                dest_dir = into / rel_root / d
                if dest_dir.exists() and not dest_dir.is_dir():
                    conflicts.append((rel, owners.get(rel), src))
                    _remove(dest_dir)
                dest_dir.mkdir(parents=True, exist_ok=True)
                owners[rel] = src
            for f in files:
                rel = rel_root / f
                dest = into / rel
                src_file = Path(root) / f
                if dest.is_dir():
                    conflicts.append((rel, owners.get(rel), src))
                    _remove(dest)
                prior = owners.get(rel)
                if dest.exists():
                    # The wheel extractor treats any execute bit as executable
                    # (py/tools/unpack/unpack.py). Other mode differences may
                    # reflect executor umask and are benign for identical data.
                    if filecmp.cmp(str(src_file), str(dest), shallow=False):
                        src_executable = bool(src_file.stat().st_mode & 0o111)
                        dest_executable = bool(dest.stat().st_mode & 0o111)
                        if src_executable != dest_executable:
                            conflicts.append((rel, prior, src))
                        shutil.copymode(str(src_file), str(dest))
                        owners[rel] = src
                        continue
                    conflicts.append((rel, prior, src))
                    _remove(dest)
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

    conflicts = merge(args.into, args.sources)

    if conflicts and args.collision_policy != "ignore":
        for rel, previous, current in conflicts:
            print(
                "Package collision while merging {}: `{}` is provided by both {} and {}.".format(
                    args.into, rel, previous, current
                ),
                file=sys.stderr,
            )
        if args.collision_policy == "error":
            raise SystemExit(
                'Set `package_collisions = "warning"` or "ignore" to downgrade.'
            )


if __name__ == "__main__":
    main()
