import sys

def test_default_py_version():
    assert sys.version_info.major == 3, "sys.version_info.major == 3"
    assert sys.version_info.minor == 9, "sys.version_info.minor == 9"
