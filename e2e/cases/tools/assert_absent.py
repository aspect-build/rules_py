"""Fail if a tar-listing file contains any forbidden path substring.

Docker-free guard wired into `assert_tar_listing`: it scans the same layer
listing the snapshot test diffs, but asserts an *invariant* rather than exact
bytes, so it keeps holding even when a snapshot is regenerated.

Guards the packaging policy that otherwise only surfaces inside a running
container:

  * `py_image_layer`'s pip-package layer strips `__pycache__`/`.pyc` and
    install metadata (see `_should_skip_pkg_path`). Nothing may smuggle them
    back in — in particular a reintroduced `_wheels/<key>` venv tree, which
    ships as a distinct declared output the source-layer dedup doesn't catch,
    re-injecting both the duplicate wheel files and the stripped bytecode.

Usage (from the macro): assert_absent.py <listing-file> <forbidden>...
"""

import sys


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: assert_absent.py <listing-file> <forbidden>...")
    listing_path = argv[1]
    forbidden = argv[2:]

    with open(listing_path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    failures = []
    for line in lines:
        for pat in forbidden:
            if pat in line:
                failures.append((pat, line.strip()))

    if failures:
        msg = ["{} forbidden path(s) in {}:".format(len(failures), listing_path)]
        for pat, line in failures[:20]:
            msg.append("  [{}] {}".format(pat, line))
        if len(failures) > 20:
            msg.append("  ... ({} more)".format(len(failures) - 20))
        sys.exit("\n".join(msg))

    print("assert_absent: ok ({} lines, none matched {})".format(len(lines), forbidden))


if __name__ == "__main__":
    main(sys.argv)
