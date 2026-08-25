"""Assert aspect-declared layer tars are action-shared between two image targets."""

import argparse


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shared-suffix", action="append", default=[])
    parser.add_argument("--first", nargs="+", required=True)
    parser.add_argument("--second", nargs="+", required=True)
    args = parser.parse_args()

    for suffix in args.shared_suffix:
        first = [path for path in args.first if path.endswith(suffix)]
        second = [path for path in args.second if path.endswith(suffix)]
        if len(first) != 1 or len(second) != 1:
            parser.error(
                "expected exactly one layer ending in {!r} per target, found {} and {}".format(
                    suffix, len(first), len(second)
                )
            )
        if first[0] != second[0]:
            parser.error(
                "layer ending in {!r} is not action-shared: {!r} vs {!r}".format(suffix, first[0], second[0])
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
