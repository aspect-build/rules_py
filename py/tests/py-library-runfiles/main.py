import library


def test_library_source_is_available() -> None:
    assert library.VALUE == "source-runfiles-ok"


if __name__ == "__main__":
    test_library_source_is_available()
