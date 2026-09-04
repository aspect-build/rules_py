"""Smoke test for msgpack built from its sdist.

A round-trip through msgpack's compiled Cython extension (_cmsgpack)
must reproduce the exact same structure, including nested types.
"""

import unittest

import msgpack


class TestMsgpack(unittest.TestCase):
    def test_round_trip(self) -> None:
        payload = {"a": 1, "b": [1, 2, 3], "c": "text", "d": None, "e": True}
        packed = msgpack.packb(payload)
        unpacked = msgpack.unpackb(packed, raw=False)
        self.assertEqual(unpacked, payload)


if __name__ == "__main__":
    unittest.main()
