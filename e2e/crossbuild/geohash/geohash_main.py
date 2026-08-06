#!/usr/bin/env python3

import geohash


def main() -> None:
    encoded = geohash.encode(37.7749, -122.4194)
    assert encoded == "9q8yyk8ytpxr", "geohash.encode returned {!r}, expected '9q8yyk8ytpxr'".format(encoded)
    print("OK")


if __name__ == "__main__":
    main()
