import data_plugin


def test_data_python_dependency_sources_are_available() -> None:
    assert data_plugin.VALUE == "plugin-helper"


if __name__ == "__main__":
    test_data_python_dependency_sources_are_available()
