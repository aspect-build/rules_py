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

from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import stat
import sys
from pathlib import Path
from types import TracebackType
from collections.abc import Callable, Sequence


def _remove(path: Path) -> None:
    """Remove an output copied from a potentially read-only input."""

    def retry_readonly(
        function: Callable[..., object],
        candidate: str,
        exc_info: tuple[type[BaseException], BaseException, TracebackType],
    ) -> None:
        error = exc_info[1]
        if not isinstance(error, PermissionError):
            raise error
        candidate_path = Path(candidate)
        candidate_path.chmod(candidate_path.stat().st_mode | stat.S_IWRITE)
        function(candidate_path)

    if path.is_dir():
        shutil.rmtree(path, onerror=retry_readonly)
        return
    try:
        path.unlink()
    except PermissionError:
        path.chmod(path.stat().st_mode | stat.S_IWRITE)
        path.unlink()


def merge(into: Path, sources: Sequence[Path]) -> list[tuple[Path, Path | None, Path]]:
    into.mkdir(parents=True, exist_ok=True)
    owners: dict[Path, Path] = {}
    caches: dict[Path, list[Path]] = {}
    conflicts: list[tuple[Path, Path | None, Path]] = []

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
                # Bytecode belongs to whoever wrote the source; a wheel that
                # replaces `mod.py` invalidates caches merged before it.
                for cache in caches.pop(rel, ()):
                    _remove(into / cache)
                shutil.copy(str(src_file), str(dest))
                owners[rel] = src
                if rel.parent.name == "__pycache__" and rel.name.endswith(".pyc"):
                    source = cache_source_path(rel)
                    if source is not None:
                        caches.setdefault(source, []).append(rel)

    return conflicts


def cache_source_path(path: Path) -> Path | None:
    """Return the source a `.pyc` is reached through, or None if unreachable.

    Cache tags are stripped right to left, so a dotted source such as
    `mod.v1.py` resolves from `mod.v1.cpython-311.pyc`. Keep in sync with
    cache_source_path in py/tools/unpack/unpack.py and the shared test vectors.
    """
    if not path.name.endswith(".pyc"):
        return None
    if path.parent.name != "__pycache__":
        return path.with_name(path.name[:-len(".pyc")] + ".py")
    source, separator, tag = path.name[:-len(".pyc")].rpartition(".")
    if tag.startswith("opt-"):
        if not tag[len("opt-"):]:
            return None
        source, separator, tag = source.rpartition(".")
    if not source or not separator or not tag:
        return None
    return path.parent.parent / (source + ".py")


def main() -> None:
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
