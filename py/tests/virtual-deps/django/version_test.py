import os

# EXPECT_DJANGO_VERSION: a version string the resolution must produce, or the
# empty string when the resolution removes django and the import must fail.
expected = os.environ["EXPECT_DJANGO_VERSION"]

if expected == "":
    try:
        import django
    except ImportError:
        pass
    else:
        raise AssertionError(f"django unexpectedly importable at {django.__file__}")
else:
    import django

    got = django.get_version()
    assert got == expected, f"expected django {expected}, got {got}"
