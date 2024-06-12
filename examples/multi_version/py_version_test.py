import sys

def test_specific_py_version():
    assert sys.version_info.major == 3, "sys.version_info.major == 3"
    assert sys.version_info.minor == 8, "sys.version_info.minor == 8"
    assert sys.version_info.micro == 12, "sys.version_info.micro == 12"
