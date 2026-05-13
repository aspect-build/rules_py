"""Regression test for fix(uv): pin sdist build tools to configured Python.

The project pins `python_version = "3.10"` on `uv.project()`. Importing the
sdist-built python-geohash here only confirms the *consumer venv* runs
under 3.10 — that comes from this py_test's own `python_version` attr and
proves nothing about the build helper.

To prove `build_tool` itself ran under 3.10 (not the exec-config default,
3.11 in this e2e), we inspect the C extension shipped in the wheel:
CPython names extensions with the building interpreter's ABI tag, e.g.
`_geohash.cpython-310-x86_64-linux-gnu.so`. If `build_tool` had inherited
the exec-config 3.11, the .so would carry `cpython-311` and either (a)
fail to install into the 3.10 venv or (b) fail to import under 3.10.
"""

import os
import sys

import geohash


def test_python_version():
    assert sys.version_info[:2] == (3, 10), (
        "expected python 3.10 at runtime, got {}.{}".format(*sys.version_info[:2])
    )


def test_extension_built_for_3_10():
    pkg_dir = os.path.dirname(geohash.__file__)
    extensions = [f for f in os.listdir(pkg_dir) if f.endswith(".so")]
    assert extensions, "no native extension shipped with geohash in {}".format(pkg_dir)
    # The ABI tag is stamped into the filename by the building interpreter;
    # the project asked for 3.10, so the build_tool must have produced cp310.
    for so in extensions:
        assert "cpython-310" in so, (
            "expected cpython-310 ABI tag (build_tool should run under the "
            "project's python_version), got {} in {}".format(so, pkg_dir)
        )


def test_encode_decode():
    lat, lon = 37.7749, -122.4194
    encoded = geohash.encode(lat, lon)
    assert encoded, "geohash.encode should return a non-empty string"
    decoded = geohash.decode(encoded)
    assert len(decoded) == 2, "geohash.decode should return (lat, lon)"


if __name__ == "__main__":
    test_python_version()
    test_extension_built_for_3_10()
    test_encode_decode()
    print("OK")
