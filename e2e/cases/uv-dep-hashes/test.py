import colorama


def test_imported() -> None:
    assert hasattr(colorama, "Fore")


if __name__ == "__main__":
    test_imported()
    print("OK")
