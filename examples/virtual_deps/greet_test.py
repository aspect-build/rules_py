import pytest
from greet import greet

def test_greet_contains_input():
    input = "Hello Alice!"
    assert input in greet(input), ""
