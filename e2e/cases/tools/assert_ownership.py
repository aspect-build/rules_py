"""Fail if any row in a tar listing has an unexpected numeric uid/gid.

Docker-free guard for `py_layer_tier(owner = ..., group = ...)`: every layer
kind (pip whole-package, pip subpath split, first-party group, interpreter,
squashed ungrouped pip, rule-level group, default source) routes through its
own mtree emitter, so a missed emitter shows up here as rows still owned by
0/0.

`bsdtar -tv` columns are: mode, nlink, uid, gid, size, month, day, year, path.

Usage (from the macro): assert_ownership.py <listing-file> <uid> <gid>
"""

import sys


def main(argv: list[str]) -> None:
    if len(argv) != 4:
        sys.exit("usage: assert_ownership.py <listing-file> <uid> <gid>")
    listing_path, want_uid, want_gid = argv[1:]

    with open(listing_path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    failures = []
    rows = 0
    for line in lines:
        if not line.startswith("  - "):
            continue
        fields = line[4:].split()
        if len(fields) < 9:
            sys.exit("unparseable listing row: {}".format(line))
        rows += 1
        if fields[2] != want_uid or fields[3] != want_gid:
            failures.append(line.strip())

    if not rows:
        sys.exit("no listing rows found in {}".format(listing_path))

    if failures:
        msg = [
            "{} of {} rows in {} are not owned by {}:{}:".format(
                len(failures), rows, listing_path, want_uid, want_gid
            )
        ]
        msg.extend("  " + line for line in failures[:20])
        sys.exit("\n".join(msg))

    print("ok: {} rows owned by {}:{}".format(rows, want_uid, want_gid))


if __name__ == "__main__":
    main(sys.argv)
