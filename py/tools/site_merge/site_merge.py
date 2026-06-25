"""Merge compatible package directories into one action-owned output.

Invoked by Bazel as::

    <exec_python> site_merge.py --into <dir> --src <path> [--src <path> ...]

Sources must be directories. Their disjoint entries form a union, while
overlapping claims must have the same type and value. Bazel may present
tree-artifact files as sandbox symlinks; these are dereferenced before
comparison and copying. Sources that do not exist are skipped
(platform-specific inputs may be absent on the current platform).
"""

import argparse
import filecmp
import os
import shutil
import stat
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Claim:
    kind: str
    owner: Path
    source: Path


class MergeConflict(ValueError):
    pass


def _kind(path):
    if path.is_file():
        return "regular file"
    if path.is_dir():
        return "directory"
    return "unsupported file type"


def _executable_bits(path):
    return stat.S_IMODE(path.stat().st_mode) & 0o111


def _conflict(relative, first, second, reason):
    raise MergeConflict(
        "merge conflict at {}: owners {} and {}: {}".format(
            relative, first.owner, second.owner, reason
        )
    )


def _compare_claims(relative, first, second):
    if first.kind != second.kind:
        _conflict(
            relative,
            first,
            second,
            "type differs ({} vs {})".format(first.kind, second.kind),
        )
    if first.kind == "regular file":
        if not filecmp.cmp(first.source, second.source, shallow=False):
            _conflict(relative, first, second, "regular file contents differ")
        first_executable = _executable_bits(first.source)
        second_executable = _executable_bits(second.source)
        if first_executable != second_executable:
            _conflict(
                relative,
                first,
                second,
                "executable bits differ ({:03o} vs {:03o})".format(
                    first_executable, second_executable
                ),
            )


def _record(claims, relative, owner, source):
    claim = Claim(_kind(source), owner, source)
    if claim.kind == "unsupported file type":
        raise MergeConflict(
            "merge conflict at {}: owner {}: unsupported file type".format(
                relative, owner
            )
        )
    previous = claims.get(relative)
    if previous is None:
        claims[relative] = claim
    else:
        _compare_claims(relative, previous, claim)

    if claim.kind == "directory":
        for child in sorted(source.iterdir(), key=lambda path: path.name):
            _record(claims, relative / child.name, owner, child)


def _materialize(into, claims):
    into.mkdir(parents=True, exist_ok=True)
    if any(into.iterdir()):
        raise ValueError("output directory is not empty: {}".format(into))

    for relative, claim in sorted(
        claims.items(), key=lambda item: (len(item[0].parts), item[0].parts)
    ):
        destination = into / relative
        if claim.kind == "directory":
            destination.mkdir()
        elif claim.kind == "regular file":
            shutil.copyfile(claim.source, destination)
            shutil.copymode(claim.source, destination)
        else:
            raise AssertionError("unexpected claim kind: {}".format(claim.kind))


def merge(into, sources):
    claims = {}
    found_source = False
    for source in sorted(sources, key=os.fspath):
        if not os.path.lexists(source):
            continue
        found_source = True
        if not source.is_dir():
            raise MergeConflict(
                "merge source {} is a {}; only directories can be merged".format(
                    source, _kind(source)
                )
            )
        for child in sorted(source.iterdir(), key=lambda path: path.name):
            _record(claims, Path(child.name), source, child)

    if not found_source:
        raise ValueError("no source paths exist")
    _materialize(into, claims)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--into", required=True, type=Path)
    parser.add_argument("--src", dest="sources", action="append", default=[], type=Path)
    args = parser.parse_args()

    try:
        merge(args.into, args.sources)
    except (MergeConflict, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
