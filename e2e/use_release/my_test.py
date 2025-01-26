from __init__ import welcome

def test_welcome():
    greeting = welcome("world")
    assert greeting == "hello world"




