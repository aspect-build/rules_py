"""Verify that native_inputs threads a Bazel cc_library into the sdist build.

_native_inputs_check is a C extension injected into python-geohash via
pre_build_patches; it compiles against a header and links against a static
library that only exist as Bazel targets (see BUILD.bazel).
"""

import _native_inputs_check
import geohash


def test_native_inputs_value():
    assert _native_inputs_check.check_value() == 42


def test_geohash_still_works():
    encoded = geohash.encode(37.7749, -122.4194)
    assert encoded, "geohash.encode should return a non-empty string"


if __name__ == "__main__":
    test_native_inputs_value()
    test_geohash_still_works()
    print("OK")
