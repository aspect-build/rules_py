import colorama


def test_imported():
    assert hasattr(colorama, "Fore")


if __name__ == "__main__":
    test_imported()
    print("OK")
