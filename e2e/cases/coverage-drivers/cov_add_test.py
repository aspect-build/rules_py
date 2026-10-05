from foo import absolute, add, subtract


def test_add() -> None:
    assert add(1, 2) == 3


def test_subtract() -> None:
    assert subtract(5, 2) == 3


def test_absolute() -> None:
    assert absolute(-2) == 2
