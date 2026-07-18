"""Verify that python-geohash (built from sdist via pep517_native_whl) is importable."""

import ctypes

import _geohash
import geohash


def test_encode_decode() -> None:
    lat, lon = 37.7749, -122.4194
    encoded = geohash.encode(lat, lon)
    assert encoded, "geohash.encode should return a non-empty string"
    decoded = geohash.decode(encoded)
    assert len(decoded) == 2, "geohash.decode should return (lat, lon)"


def test_cxx_runtime():
    extension = ctypes.CDLL(_geohash.__file__)
    probe = extension.rules_py_cxx_runtime_probe
    probe.restype = ctypes.c_char_p
    assert probe() == b"rules_py_cxx_runtime_probe"


if __name__ == "__main__":
    test_encode_decode()
    test_cxx_runtime()
    print("OK")
