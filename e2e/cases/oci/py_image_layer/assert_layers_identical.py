"""Assert two image targets produce byte-identical layers, paired by name-stripped path."""

import argparse
import filecmp


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--first-name", required=True)
    parser.add_argument("--second-name", required=True)
    parser.add_argument("--expect-layer", action="append", default=[])
    parser.add_argument("--first", nargs="+", required=True)
    parser.add_argument("--second", nargs="+", required=True)
    args = parser.parse_args()

    first = {path.replace(args.first_name, "{}"): path for path in args.first}
    second = {path.replace(args.second_name, "{}"): path for path in args.second}
    if first.keys() != second.keys():
        parser.error("layer sets differ: {} vs {}".format(sorted(first), sorted(second)))

    for key in sorted(first):
        # Identical paths mean a single shared artifact; nothing to compare.
        if first[key] == second[key]:
            continue
        if not filecmp.cmp(first[key], second[key], shallow=False):
            parser.error("layer {!r} differs: {!r} vs {!r}".format(key, first[key], second[key]))

    for suffix in args.expect_layer:
        if not any(key.endswith(suffix) for key in first):
            parser.error("missing expected layer ending in {!r}".format(suffix))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
