#!/usr/bin/env python3
import msgpack


def main() -> None:
    # A round-trip through msgpack's compiled Cython extension (_cmsgpack)
    # must reproduce the exact same structure, including nested types.
    payload = {"a": 1, "b": [1, 2, 3], "c": "text", "d": None, "e": True}
    packed = msgpack.packb(payload)
    unpacked = msgpack.unpackb(packed, raw=False)
    assert unpacked == payload, "round-trip produced {!r}, expected {!r}".format(unpacked, payload)
    print("OK")


if __name__ == "__main__":
    main()
