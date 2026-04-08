"""Verify that python-geohash (built from sdist via pep517_native_whl) is importable."""

import geohash


def test_encode_decode():
    lat, lon = 37.7749, -122.4194
    encoded = geohash.encode(lat, lon)
    assert encoded, "geohash.encode should return a non-empty string"
    decoded = geohash.decode(encoded)
    assert len(decoded) == 2, "geohash.decode should return (lat, lon)"


if __name__ == "__main__":
    test_encode_decode()
    print("OK")
