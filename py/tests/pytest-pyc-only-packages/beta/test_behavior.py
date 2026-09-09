import support


def test_behavior() -> None:
    assert __package__ == "beta"
    assert support.VALUE == 1
