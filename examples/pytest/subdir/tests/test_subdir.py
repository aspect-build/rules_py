
def test_import_foo():
    from foo import foo_func
    assert foo_func() == "foo"
