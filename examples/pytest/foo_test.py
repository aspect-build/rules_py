import pytest
import json

from examples.pytest.foo import add

def test_add():
    assert add(1, 1) == 2, "Expected 1 + 1 to equal 2"

def test_hello_json():
    content = open('fixtures/hello.json', 'r').read()
    data = json.loads(content)
    assert data["message"] == "Hello, world.", "Message is as expected"
