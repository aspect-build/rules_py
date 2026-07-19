import pytest
from greet import greet

def test_greet_contains_input() -> None:
    input = "Hello Alice!"
    assert input in greet(input), ""
