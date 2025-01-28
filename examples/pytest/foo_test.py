import json

import os

from examples.pytest.foo import add

def test_add():
    assert add(1, 1) == 2, "Expected 1 + 1 to equal 2"

def test_hello_json():
    # NB: we don't use the chdir attribute so the test working directory is the repository root
    content = open(os.path.join(os.getenv('TEST_TARGET').lstrip('/').split(':')[0], 'fixtures/hello.json'), 'r').read()
    data = json.loads(content)
    assert data["message"] == "Hello, world.", "Message is as expected"
