import support


def test_dependency_is_sourceless() -> None:
    assert support.__file__.endswith(".pyc"), support.__file__
