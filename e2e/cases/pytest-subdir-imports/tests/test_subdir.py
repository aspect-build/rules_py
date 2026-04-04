from lib import hello

def test_import_from_parent():
    assert hello() == "hello from subdir import"
