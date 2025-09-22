from src import welcome

def test_welcome():
    greeting = welcome("world2")
    assert greeting == "hello world2"




