import pytest

from examples.pytest.foo import add

def test_add():
    assert add(1, 1) == 2, "Expected 1 + 1 to equal 2"
