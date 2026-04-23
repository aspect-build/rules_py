from get_python_package_version import get_packaging_version


def test_get_packaging_version_matches_humble():
    assert get_packaging_version() == "21.3"
