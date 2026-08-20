"""Assert the given files contain each expected substring."""

import argparse


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expect", action="append", default=[])
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()

    content = ""
    for path in args.files:
        with open(path) as fh:
            content += fh.read()
    for expected in args.expect:
        if expected not in content:
            parser.error("missing expected content {!r} in {}".format(expected, args.files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
