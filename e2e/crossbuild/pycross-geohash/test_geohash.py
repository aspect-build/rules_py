"""Smoke test for python-geohash built from its sdist.

require_cxx_driver.patch makes the C++ extension mandatory, so a passing
import and encode here means the native build ran — the upstream pure-Python
fallback cannot have papered over a compile failure.
"""

import unittest

import geohash


class TestGeohash(unittest.TestCase):
    def test_encode(self) -> None:
        encoded = geohash.encode(37.7749, -122.4194)
        self.assertEqual(encoded, "9q8yyk8ytpxr")


if __name__ == "__main__":
    unittest.main()
