"""Verify that jpype1 (built from sdist via pep517_native_whl with
needs-jdk = true) is importable.

If `needs-jdk` doesn't propagate, the sdist build fails because JPype1's
setup.py can't find <jni.h>, and this test never gets a chance to run.
"""

import jpype


def test_import() -> None:
    assert jpype.__version__, "jpype.__version__ should be a non-empty string"


if __name__ == "__main__":
    test_import()
    print("OK")
