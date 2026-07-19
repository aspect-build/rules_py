
def test_import_foo() -> None:
    from foo import foo_func
    assert foo_func() == "foo"
