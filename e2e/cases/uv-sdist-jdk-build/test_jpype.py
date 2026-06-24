"""Verify that jpype1 built with an explicit JDK build-tool target is importable.

If the configured JAVA_HOME does not reach the backend, the sdist build fails
because JPype1's setup.py cannot find <jni.h>.
"""

import jpype


def test_import():
    assert jpype.__version__, "jpype.__version__ should be a non-empty string"


if __name__ == "__main__":
    test_import()
    print("OK")
