"""Assert that each shared source-layer sentinel is present exactly once."""

import sys


def main(argv: list[str]) -> None:
    listing, sentinels = argv[1], argv[2:]
    with open(listing, encoding="utf-8") as f:
        entries = f.read().splitlines()

    failures = []
    for sentinel in sentinels:
        count = sum(entry.endswith(sentinel) for entry in entries)
        if count != 1:
            failures.append("{}: expected once, found {}".format(sentinel, count))
    if failures:
        sys.exit("\n".join(failures))

    print("assert_source_dedup: ok ({})".format(", ".join(sentinels)))


if __name__ == "__main__":
    main(sys.argv)
